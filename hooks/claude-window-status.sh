#!/bin/bash
# Claude Code hook for VSCode Switcher.
#
# Reads a hook payload from stdin, derives a coarse agent state and writes it
# atomically to $STATUS_DIR/<session_id>.json. Installed for UserPromptSubmit,
# PermissionRequest, PostToolUse, Stop, Notification and SessionEnd.
#
# The script is deliberately defensive: any missing field, missing tool or
# unexpected payload results in a silent exit 0, because a failing hook would
# surface as an error inside the user's Claude session.
#
# Debugging: with VSCODE_SWITCHER_DEBUG=1 the raw stdin payload is appended to
# $STATUS_DIR/_debug.jsonl so the real payload schema can be inspected. That
# file contains whole prompts and assistant replies, so it is opt-in and capped.

# Byte semantics, not character semantics. Every comparison this script makes is
# against an ASCII literal, but in a UTF-8 locale bash walks a multi-megabyte
# payload character by character: on a 5 MB PostToolUse body the head slice
# below costs 31 ms and a glob over the whole payload 107 ms, against 4.4 ms for
# the slice and the match together under LC_ALL=C (measurements in SPEC §2.6.3).
# Nothing is lost: the payload's own UTF-8 text is only ever copied around, and
# the one case conversion further down folds ASCII by design.
export LC_ALL=C

STATUS_DIR="${VSCODE_SWITCHER_STATUS_DIR:-$HOME/.claude/window-status}"
DEBUG_MAX_BYTES=4194304

payload=$(cat 2>/dev/null)

# PostToolUse is the one event on a hot path: it fires after *every* tool call,
# while the rest fire a handful of times per turn. Its only job here is to end a
# permission wait the moment the approved tool actually runs — before this, the
# orange indicator stayed on until the whole turn ended, because `permission` is
# by design only cleared by a later hook. So it exits before spawning jq unless
# there is a permission wait to clear, using only shell built-ins from there on:
# beyond the `cat` that reads stdin (a builtin `read -r -d ""` would do it
# without the fork, but it consumes a pipe one byte at a time — two seconds on a
# 5 MB payload against 31 ms) nothing else is forked and nothing is read from
# disk except one small state file.
#
# The head is cut *first* and the event name is matched inside the head only: a
# glob over the whole payload would walk the entire tool response — megabytes
# for a large file read — to find a key that sits in the first few hundred
# bytes. The window is far wider than needed (the key ends by byte 580 in all
# 1865 payloads captured, and it is preceded only by `session_id`,
# `transcript_path` and `cwd`); an event name that still falls outside it simply
# takes the slow path below, which is correct, only slower.
head=${payload:0:2048}
case $head in
*'"hook_event_name": "PostToolUse"'* | *'"hook_event_name":"PostToolUse"'*)
	if [[ $head =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
		probe="$STATUS_DIR/${BASH_REMATCH[1]}.json"
		[ -s "$probe" ] || exit 0
		current=""
		read -r -d '' current <"$probe" 2>/dev/null
		# The match runs over the whole file, and `"state": "permission"` also
		# occurs inside every element of `waits`. It cannot fire falsely on
		# those: the top-level `state` is the maximum over the list and the key
		# is left out while the list is empty, so a nested occurrence only ever
		# exists in a record whose top-level state already matches. Nothing
		# rests on that invariant anyway — a false positive costs the slow path,
		# which then exits on the `prev_state` guard below.
		case "$current" in
		*'"state": "permission"'* | *'"state":"permission"'* | \
			*'"state": "question"'* | *'"state":"question"'*) ;;
		*) exit 0 ;;
		esac
	fi
	;;
esac

# Both of these come after the early exit, not before it. `mkdir` is a
# subprocess, and the exit above is meant to run without spawning any; with
# debugging on, dumping every payload would append the whole tool response of
# every tool call in every session, and a PostToolUse body is megabytes for a
# large file read. The events that survive to here are the ones that change the
# state, which is what the dump is for.
mkdir -p "$STATUS_DIR" 2>/dev/null

# The dump holds raw payloads — whole prompts and assistant replies — so it is
# capped rather than left to grow: one rotation at 4 MiB keeps the recent
# payloads (the interesting ones) and bounds the total at twice that. It ran to
# 6.8 MB of chat text in a fortnight before the cap existed.
if [ "${VSCODE_SWITCHER_DEBUG:-0}" = "1" ]; then
	debug_log="$STATUS_DIR/_debug.jsonl"
	debug_size=$(stat -f %z "$debug_log" 2>/dev/null || echo 0)
	if [ "${debug_size:-0}" -ge "$DEBUG_MAX_BYTES" ]; then
		mv -f "$debug_log" "$debug_log.1" 2>/dev/null
	fi
	printf '%s\n' "$payload" >>"$debug_log" 2>/dev/null
fi

# Hooks run with a minimal PATH, so jq has to be located explicitly.
JQ=$(command -v jq 2>/dev/null)
if [ -z "$JQ" ]; then
	for candidate in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
		if [ -x "$candidate" ]; then
			JQ="$candidate"
			break
		fi
	done
fi
[ -z "$JQ" ] && exit 0

# Pull every field we might need in one pass. Control characters are flattened
# to spaces so the record stays on a single line whatever the payload contains,
# and the fields are joined with US (0x1f): tab counts as IFS whitespace, which
# would make `read` collapse runs of empty fields and shift the values.
#
# Not @tsv: that escapes backslashes as well, and nothing ever unescapes them,
# so a cwd of `/a\b` reached the switcher as `/a\\b` and matched no project.
fields=$(printf '%s' "$payload" | "$JQ" -r '
	def s: (if . == null then "" elif type == "string" then . else tostring end)
		| gsub("[[:cntrl:]]"; " ");
	[
		((.session_id // .sessionId // "") | s),
		((.cwd // .workspace.current_dir // .workspace.project_dir // "") | s),
		((.hook_event_name // .hookEventName // "") | s),
		((.type // .notification_type // .notificationType // .subtype // "") | s),
		((.message // .notification // .title // "") | s),
		((.reason // .stop_reason // "") | s),
		((.transcript_path // .transcriptPath // "") | s),
		((.tool_name // .toolName // "") | s),
		((.agent_id // .agentId // "") | s)
	] | join([31] | implode)
' 2>/dev/null)
[ -z "$fields" ] && exit 0

IFS=$'\037' read -r session_id cwd event notif_type message reason transcript tool_name agent_id <<EOF
$fields
EOF

[ -z "$session_id" ] && exit 0

target="$STATUS_DIR/$session_id.json"

if [ "$event" = "SessionEnd" ]; then
	rm -f "$target" "$STATUS_DIR/$session_id.metrics.json" 2>/dev/null
	exit 0
fi

# Notification is the only event whose meaning depends on the payload body.
# Claude sends `message`, `title` and `notification_type`; the types observed
# in the CLI are permission_prompt, worker_permission_prompt,
# elicitation_dialog, elicitation_url_dialog, idle_prompt, auth_success,
# computer_use_enter/exit, elicitation_complete and elicitation_response.
# Only the first group means "the agent is blocked on the user", so unrelated
# types must leave the state alone instead of downgrading it. Unknown types
# fall back to a heuristic over the message text.
# Prints "permission", "waiting", or nothing when the event is irrelevant.
classify_notification() {
	case "$notif_type" in
	*permission* | elicitation_dialog | elicitation_url_dialog)
		printf 'permission'
		return
		;;
	idle_prompt)
		printf 'waiting'
		return
		;;
	auth_success | computer_use_* | elicitation_complete | elicitation_response | push_notification)
		return
		;;
	esac
	lower=$(printf '%s' "$message" | tr '[:upper:]' '[:lower:]')
	case "$lower" in
	*permission* | *approve* | *approval* | *"needs your"* | *"wants to"*)
		printf 'permission'
		;;
	*"waiting for"* | *"needs your input"*)
		printf 'waiting'
		;;
	esac
}

case "$event" in
UserPromptSubmit)
	state="working"
	;;
Stop)
	state="waiting"
	;;
PermissionRequest)
	# The dialog going up, confirmed empirically on CLI 2.1.227: it lands
	# within ~100 ms of `PreToolUse`, whereas the `Notification` for the same
	# dialog arrives six seconds later — and only when the user has stepped
	# away. This is the reliable source; Notification stays as a second one
	# because it also covers elicitation dialogs.
	#
	# AskUserQuestion comes through here too, and it is not a permission at
	# all: the agent is asking the user something and has stopped until it is
	# answered. Nothing else marks that — `Stop` does not fire for it
	# (verified), so without this the two are the same orange hand.
	# ExitPlanMode is assumed to arrive the same way; it has never been seen
	# in a captured payload (SPEC §2.6.2).
	case "$tool_name" in
	AskUserQuestion | ExitPlanMode) state="question" ;;
	*) state="permission" ;;
	esac
	;;
PostToolUse)
	# Only ever reached with a permission or question wait on disk (see the
	# early exit above): the tool the user approved — or the question they
	# answered — has now run, so the wait is over.
	state="working"
	;;
Notification)
	state=$(classify_notification)
	[ -z "$state" ] && exit 0
	;;
*)
	exit 0
	;;
esac

# Whatever is on disk already. Every hook runs with "async": true, so events do
# arrive out of order and a new record is merged onto the old one rather than
# replacing it wholesale.
prev="null"
if [ -s "$target" ]; then
	# Anything that is not an object is treated as no previous record at all.
	# `null.cwd` is valid jq and yields null, while `[1,2].cwd` is a fatal
	# error that would take the whole program — and with it the new state —
	# down with it.
	prev=$("$JQ" -c 'if type == "object" then . else null end' "$target" 2>/dev/null)
	[ -z "$prev" ] && prev="null"
fi
# One session can have several waits open at once, so the record carries a
# *list* of them and not a single pair. The algebra of that list is shared by
# the two jq calls below — the one that decides whether this event writes at all,
# and the writer, which recomputes the list from the file as it stands at write
# time. Deciding here rather than in the writer keeps the mismatch case a plain
# `exit 0` without a third fork: during an open dialog every background subagent
# tool call lands on it.
JQ_WAITS='
	# Every wait currently open, read back from the record. Older versions of
	# this script wrote a single waitTool/waitAgent pair and older ones still
	# wrote neither, so both shapes have to load — a record stuck in a shape
	# nothing understands would hold an orange indicator until the session ends.
	def waitsof:
		if type != "object" then []
		elif (.waits | type) == "array"
		then [.waits[]
			| select(type == "object" and (.tool | type) == "string" and .tool != "")
			| {tool: .tool,
			   agent: (if (.agent | type) == "string" then .agent else "" end),
			   state: (if .state == "question" then "question" else "permission" end)}]
		elif (.waitTool | type) == "string" and .waitTool != ""
		then [{tool: .waitTool,
		       agent: (if (.waitAgent | type) == "string" then .waitAgent else "" end),
		       state: (if .state == "question" then "question" else "permission" end)}]
		else [] end;
	# A wait is named by the pair PermissionRequest carries: which agent asked
	# and which tool it asked for. Asking twice for the same pair is one wait.
	def drop($t; $a): map(select(.tool != $t or .agent != $a));
	# The row shows the most urgent wait still open (§3 order), so clearing a
	# subagent permission cannot take the main agent question off the screen.
	def worst($fallback):
		if any(.state == "question") then "question"
		elif length > 0 then "permission"
		else $fallback end;
	# The list once this event has been applied to the record it is called on.
	def nextwaits($event; $state; $tool; $agent):
		waitsof as $open
		| if $event == "PostToolUse" then ($open | drop($tool; $agent))
		  elif $event == "PermissionRequest" and $tool != ""
		  then ($open | drop($tool; $agent))
		       + [{tool: $tool, agent: $agent, state: $state}]
		  # Anything else that keeps the state a wait — the Notification trailing
		  # six seconds behind a dialog — carries the open ones along, or they
		  # could never be cleared by the tools they belong to.
		  elif $state == "permission" or $state == "question" then $open
		  else [] end;
'

# What was on disk a moment ago: the state, for the Notification guards, and
# whether this PostToolUse has a wait of its own to clear. Only the decision is
# taken from this read — the list itself is rebuilt by the writer.
IFS=$'\037' read -r prev_state clears <<EOF
$(printf '%s' "$prev" | "$JQ" -r \
	--arg toolName "$tool_name" \
	--arg agentId "$agent_id" "$JQ_WAITS"'
	[(.state // ""),
	 # Empty means "do not write": a PostToolUse whose pair matches no open
	 # wait belongs to somebody else.
	 (if (waitsof | any(.tool == $toolName and .agent == $agentId))
	  then "yes" else "" end)]
	| join([31] | implode)
' 2>/dev/null)
EOF

# PostToolUse ends a wait and nothing else. The fast path above already exits
# for any other case, but that path matches a literal string in the payload, and
# correctness must not hang off the CLI's JSON spacing: with the match missed,
# every tool call would land here, and an async PostToolUse delivered after the
# `Stop` it preceded would turn an answered chat back into a working one.
#
# And it ends *its own* wait. A session is one `session_id` but many agents:
# every background subagent's tool call arrives here under the parent's
# `session_id`, with its own `agent_id`. Caught in the wild: the main agent had
# an `AskUserQuestion` dialog on screen and a subagent's `Bash` finished, which
# cleared it — the yellow chip vanished while the question was still waiting for
# an answer. Nothing brings a wait cleared by mistake back: `permission` is
# invisible to the transcript, and `question` cannot be recovered from it either,
# because the transcript of an agent blocked on a dialog stops growing while the
# subagent writes to its own session file — and the transcript is only allowed to
# overrule the hook when it is provably newer (SPEC §2.6.3).
#
# `PermissionRequest` carries no `tool_use_id`, so the wait is keyed on the pair
# that it does carry: which agent asked and which tool it asked for. An absent
# `agent_id` is not "unknown" — it is how the session's own top-level agent
# looks, in every payload captured — so both sides being empty is a match, and
# only then. A wait with no tool recorded (one raised by `Notification`, or by
# an older version of this script) is never cleared here: `Stop` and
# `UserPromptSubmit` still clear it, and holding an orange indicator too long
# beats dropping it while the dialog is up.
#
# Whether any wait matches was worked out by the jq call above; an empty
# `clears` is its way of saying that this tool call clears nothing here.
if [ "$event" = "PostToolUse" ]; then
	case "$prev_state" in
	permission | question) ;;
	*) exit 0 ;;
	esac
	[ -z "$clears" ] && exit 0
fi

# A Notification never clears a permission or question wait. `idle_prompt` only
# says the user has not typed for a while — which is exactly what happens while a
# permission dialog sits on screen — and the guard must not depend on the type
# being present: a payload without `notification_type` falls through to the
# text heuristic, `"Claude is waiting for your input"` classifies as `waiting`,
# and the orange indicator went green with the dialog still open.
# `notification_type` was confirmed empirically for exactly one value on one CLI
# version, so it is evidence, not a precondition. Only `Stop`, `UserPromptSubmit`
# and `PostToolUse` take `permission` off.
if [ "$event" = "Notification" ] && [ "$state" = "waiting" ]; then
	case "$prev_state" in
	permission | question) exit 0 ;;
	esac
fi

# Nor does the Notification that trails a PermissionRequest by six seconds get
# to turn a question back into a plain permission: it says only
# "Claude needs your permission" and carries no tool name, so it cannot tell the
# two apart, while the PermissionRequest that preceded it could.
if [ "$event" = "Notification" ] && [ "$state" = "permission" ] && [ "$prev_state" = "question" ]; then
	exit 0
fi

# The record is rebuilt from the file as it stands *now*, not from the copy read
# a few milliseconds ago. Between that read and this write sit a jq run and a
# `date`, and two PostToolUse from different subagents landing inside that window
# would both compute their new list from the same old one — the second to write
# would resurrect the wait the first had cleared, and it would then hold the
# indicator until the end of the turn. Reading again here shrinks the window to
# one jq run; it does not close it, because the read and the rename are still not
# one operation (SPEC §2.6.3).
#
# `--slurpfile` is a fatal error on a missing or damaged file rather than a null,
# so the case where nothing readable was there a moment ago hands jq an empty
# stream instead. A record that was readable then and is gone now loses the
# write, which is what a `SessionEnd` removing the file underneath should do.
if [ "$prev" = "null" ]; then
	prev_args=(--argjson prevFile '[]')
else
	prev_args=(--slurpfile prevFile "$target")
fi

tmp="$STATUS_DIR/.tmp.$session_id.$$"
"$JQ" -n \
	"${prev_args[@]}" \
	--arg sessionId "$session_id" \
	--arg cwd "$cwd" \
	--arg state "$state" \
	--arg event "$event" \
	--arg toolName "$tool_name" \
	--arg agentId "$agent_id" \
	--arg notificationType "$notif_type" \
	--arg message "$message" \
	--arg reason "$reason" \
	--arg transcript "$transcript" \
	--argjson ts "$(date +%s)" \
	"$JQ_WAITS"'
	($prevFile[0]) as $raw
	# Anything that is not an object is no previous record at all: `null.cwd` is
	# valid jq and yields null, while `[1,2].cwd` is a fatal error that would
	# take the whole program — and with it the new state — down with it.
	| (if ($raw | type) == "object" then $raw else null end) as $prev
	| ($raw | nextwaits($event; $state; $toolName; $agentId)) as $waits
	# The state written is the one left over once the list has been updated: a
	# session with two waits open keeps showing the more urgent of them rather
	# than the one that happened to move last, and a PostToolUse that emptied
	# the list gets its `working` from the fallback. The guards above
	# deliberately ran before this, on the state the event alone implies, so
	# that what a Notification is allowed to do does not depend on what the
	# list happens to hold.
	| ($waits | worst($state)) as $rowState
	|
	# A record older than the one already on disk is dropped: a delayed
	# UserPromptSubmit must not bury the Stop that overtook it. Emitting
	# nothing leaves the temporary file empty, and the caller keeps the
	# existing state.
	#
	# The type is checked before the comparison, and not only to be tidy: in
	# jq every number sorts before every string, so a `ts` of "abc" made the
	# comparison true forever and no state could ever be written again.
	if (($prev | type) == "object" and ($prev.ts | type) == "number" and $prev.ts > $ts)
	then empty else
	  # Notification payloads carry no cwd for some types; taking the empty
	  # string would blank out the path a previous event recorded.
	  {sessionId: $sessionId,
	   cwd: (if $cwd == "" then ($prev.cwd // "") else $cwd end),
	   state: $rowState,
	   event: $event,
	   ts: $ts}
	  # Who is waiting and for what, so that PostToolUse can tell its own tool
	  # from one belonging to a background subagent — a list, because a
	  # subagent can be blocked on a permission dialog while the main agent is
	  # blocked on a question, and answering one of them must not clear the
	  # other. Empty when nothing is waiting, and then the key is left out
	  # entirely.
	  + (if ($waits | length) == 0 then {} else {waits: $waits} end)
	  + (if $message == "" then {} else {message: $message} end)
	  + (if $notificationType == "" then {} else {notificationType: $notificationType} end)
	  + (if $reason == "" then {} else {reason: $reason} end)
	  + (if $transcript == "" then {} else {transcriptPath: $transcript} end)
	end' \
	>"$tmp" 2>/dev/null

if [ -s "$tmp" ]; then
	mv -f "$tmp" "$target" 2>/dev/null
else
	rm -f "$tmp" 2>/dev/null
fi

exit 0
