#!/bin/bash
# Claude Code hook for VSCode Switcher.
#
# Reads a hook payload from stdin, derives a coarse agent state and writes it
# atomically to $STATUS_DIR/<session_id>.json. Installed for UserPromptSubmit,
# PermissionRequest, PostToolUse, PostToolUseFailure, Stop, Notification and
# SessionEnd.
#
# The script is deliberately defensive: any missing field, missing tool or
# unexpected payload results in a silent exit 0, because a failing hook would
# surface as an error inside the user's Claude session.
#
# Debugging: with VSCODE_SWITCHER_DEBUG=1 the raw stdin payload is appended to
# $STATUS_DIR/_debug.jsonl (opt-in and capped: it holds whole prompts).

# Byte semantics: every comparison is against an ASCII literal, and in a UTF-8
# locale bash walks a 5 MB payload character by character (31 ms for the head
# slice, 107 ms for a full glob, against 4.4 ms under LC_ALL=C; SPEC §2.6.3).
export LC_ALL=C

STATUS_DIR="${VSCODE_SWITCHER_STATUS_DIR:-$HOME/.claude/window-status}"
DEBUG_MAX_BYTES=4194304

payload=$(cat 2>/dev/null)

# Hot path: PostToolUse fires after every successful tool call and
# PostToolUseFailure after every failed one (non-zero exit, MCP `isError`,
# JSON-RPC error; SPEC §2.6.2). Their only job is to end a permission or
# question wait once the approved tool has run, so both exit before spawning jq
# unless such a wait is on disk, using only built-ins after the `cat` (a builtin
# `read -r -d ""` reads a pipe byte by byte: two seconds on 5 MB).
#
# The event name is matched inside the first 2 KiB only: a glob over the whole
# payload would walk the entire tool response. The key ends by byte ~580 in
# observed payloads; one that falls outside the window takes the slow path,
# which is correct, only slower.
head=${payload:0:2048}
# The closing quote is part of every pattern, so `PostToolUse` does not also
# match `PostToolUseFailure` or any other name that starts the same way. The
# early exit runs before the debug dump is written, which is how the tests
# check it.
case $head in
*'"hook_event_name": "PostToolUse"'* | *'"hook_event_name":"PostToolUse"'* | \
	*'"hook_event_name": "PostToolUseFailure"'* | *'"hook_event_name":"PostToolUseFailure"'*)
	if [[ $head =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
		probe="$STATUS_DIR/${BASH_REMATCH[1]}.json"
		[ -s "$probe" ] || exit 0
		current=""
		read -r -d '' current <"$probe" 2>/dev/null
		# The match also hits `state` inside `waits` elements, which is harmless:
		# a non-empty list implies the top-level state already matches, and this
		# only decides whether jq runs; the pair check below decides the write.
		case "$current" in
		*'"state": "permission"'* | *'"state":"permission"'* | \
			*'"state": "question"'* | *'"state":"question"'*) ;;
		*) exit 0 ;;
		esac
	fi
	;;
esac

# Both of these come after the early exit: `mkdir` is a subprocess, and dumping
# every PostToolUse would append megabytes of tool output per call. The events
# that reach here are the ones that change the state.
mkdir -p "$STATUS_DIR" 2>/dev/null

# The dump holds whole prompts and replies, so it is capped: one rotation at
# 4 MiB bounds the total at twice that.
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
# Not @tsv: it escapes backslashes and nothing unescapes them, so `/a\b` would
# arrive as `/a\\b`.
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
	# The dialog going up: it lands within ~100 ms of `PreToolUse`, while the
	# matching `Notification` arrives ~6 s later and only if the user is away.
	# Notification stays as a second source because it covers elicitations.
	#
	# AskUserQuestion also arrives here and is a question, not a permission;
	# `Stop` does not fire for it. ExitPlanMode is assumed to arrive the same
	# way but has not been seen in a captured payload (SPEC §2.6.2).
	case "$tool_name" in
	AskUserQuestion | ExitPlanMode) state="question" ;;
	*) state="permission" ;;
	esac
	;;
PostToolUse | PostToolUseFailure)
	# Only reached with a permission or question wait on disk: the approved
	# tool has run, successfully or not, so the wait is over. Both payloads
	# carry `tool_name`, `agent_id` and `session_id` the same way (SPEC §2.6.2).
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
	# Anything that is not an object counts as no previous record: `[1,2].cwd`
	# is a fatal jq error that would lose the new state.
	#
	# The exit status is checked too: an object followed by trailing junk makes
	# jq print the object and fail, and the same file is fatal to `--slurpfile`
	# below, so the record would never be written again. Treating it as absent
	# rewrites the file on the next event.
	prev=$("$JQ" -c 'if type == "object" then . else null end' "$target" 2>/dev/null) || prev="null"
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
	# Every wait currently open, read back from the record. The legacy single
	# waitTool/waitAgent pair also loads, so such a record can still be cleared.
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
	# A failed call ends its wait exactly as a successful one does; it only
	# arrives under another event name (SPEC §2.6.3).
	def nextwaits($event; $state; $tool; $agent):
		waitsof as $open
		| if $event == "PostToolUse" or $event == "PostToolUseFailure"
		  then ($open | drop($tool; $agent))
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
# whether this post-tool event has a wait of its own to clear. Only the decision
# is taken from this read — the list itself is rebuilt by the writer.
IFS=$'\037' read -r prev_state clears <<EOF
$(printf '%s' "$prev" | "$JQ" -r \
	--arg toolName "$tool_name" \
	--arg agentId "$agent_id" "$JQ_WAITS"'
	[(.state // ""),
	 # Empty means "do not write": a post-tool event whose pair matches no
	 # open wait belongs to somebody else.
	 (if (waitsof | any(.tool == $toolName and .agent == $agentId))
	  then "yes" else "" end)]
	| join([31] | implode)
' 2>/dev/null)
EOF

# A post-tool event ends only its own wait. Background subagents' tool calls
# arrive under the parent's `session_id` with their own `agent_id`, and a wait
# cleared by mistake cannot be recovered from the transcript (SPEC §2.6.3).
#
# `PermissionRequest` carries no `tool_use_id`, so a wait is keyed on
# (agent_id, tool_name). An empty `agent_id` is the session's top-level agent,
# so empty matches empty. A wait with no tool recorded is never cleared here;
# `Stop` and `UserPromptSubmit` clear it.
#
# The same check keeps a late event from reviving a finished turn: a
# subagent's post-tool event can land seconds after the parent's `Stop`, which
# has emptied the list (SPEC §2.6.2). The fast path above usually catches it,
# but correctness rests on this check. No separate state check is needed: the
# written state is the worst of the list, so a matching wait implies
# `permission` or `question`.
#
# An empty `clears` from the jq call above means no wait matches.
case "$event" in
PostToolUse | PostToolUseFailure)
	[ -z "$clears" ] && exit 0
	;;
esac

# A Notification never clears a permission or question wait: `idle_prompt` (or
# a typeless "Claude is waiting for your input") also fires while a dialog sits
# on screen. Only `Stop`, `UserPromptSubmit` and the post-tool events clear it.
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

# A readable record is read again here so that two concurrent post-tool events
# do not both build on the same old list and resurrect a cleared wait. This
# narrows the race to one jq run without closing it (SPEC §2.6.3).
#
# `--slurpfile` is fatal on a missing or damaged file, so with no readable
# record jq gets an empty list instead. A record that disappeared since the
# first read loses the write, as a concurrent `SessionEnd` should.
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
	# The state written is the most urgent wait left in the list, or the state
	# of the event itself when the list is empty. The Notification guards
	# above use the event state, independent of the list.
	| ($waits | worst($state)) as $rowState
	|
	# A record older than the one on disk is dropped (a delayed
	# UserPromptSubmit must not bury a later Stop); emitting nothing leaves the
	# temporary file empty and the existing state in place. The type check
	# matters: in jq every string sorts after every number.
	if (($prev | type) == "object" and ($prev.ts | type) == "number" and $prev.ts > $ts)
	then empty else
	  # Notification payloads carry no cwd for some types; taking the empty
	  # string would blank out the path a previous event recorded.
	  {sessionId: $sessionId,
	   cwd: (if $cwd == "" then ($prev.cwd // "") else $cwd end),
	   state: $rowState,
	   event: $event,
	   ts: $ts}
	  # Who is waiting and for what; a list because several agents of one
	  # session can wait at once. The key is omitted when nothing is waiting.
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
