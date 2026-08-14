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
# $STATUS_DIR/_debug.jsonl so the real payload schema can be inspected.

STATUS_DIR="${VSCODE_SWITCHER_STATUS_DIR:-$HOME/.claude/window-status}"

payload=$(cat 2>/dev/null)

mkdir -p "$STATUS_DIR" 2>/dev/null

# PostToolUse is the one event on a hot path: it fires after *every* tool call,
# while the rest fire a handful of times per turn. Its only job here is to end a
# permission wait the moment the approved tool actually runs — before this, the
# orange indicator stayed on until the whole turn ended, because `permission` is
# by design only cleared by a later hook. So it exits before spawning jq unless
# there is a permission wait to clear, using only shell built-ins: no fork, no
# subprocess, nothing read from disk beyond one small state file.
#
# The payload is cut to its head first. `session_id` is the first key in every
# payload observed, and a PostToolUse body carries the whole tool response —
# megabytes for a large file read — which is not something to run a regex over.
case "$payload" in
*'"hook_event_name": "PostToolUse"'* | *'"hook_event_name":"PostToolUse"'*)
	head=${payload:0:400}
	if [[ $head =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
		probe="$STATUS_DIR/${BASH_REMATCH[1]}.json"
		[ -s "$probe" ] || exit 0
		current=""
		read -r -d '' current <"$probe" 2>/dev/null
		case "$current" in
		*'"state": "permission"'* | *'"state":"permission"'* | \
			*'"state": "question"'* | *'"state":"question"'*) ;;
		*) exit 0 ;;
		esac
	fi
	;;
esac

# After the early exit, not before it: with debugging on, dumping every payload
# would append the whole tool response of every tool call in every session, and
# a PostToolUse body is megabytes for a large file read. The events that survive
# to here are the ones that change the state, which is what the dump is for.
if [ "${VSCODE_SWITCHER_DEBUG:-0}" = "1" ]; then
	printf '%s\n' "$payload" >>"$STATUS_DIR/_debug.jsonl" 2>/dev/null
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
	# AskUserQuestion and ExitPlanMode come through here too, and they are
	# not a permission at all: the agent is asking the user something and has
	# stopped until it is answered. Nothing else marks that — `Stop` does not
	# fire for them (verified), so without this the two are the same orange
	# hand.
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
IFS=$'\037' read -r prev_state prev_wait_tool prev_wait_agent <<EOF
$(printf '%s' "$prev" | "$JQ" -r '[(.state // ""), (.waitTool // ""), (.waitAgent // "")] | join([31] | implode)' 2>/dev/null)
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
# an answer. `question` would come back from the transcript ninety seconds
# later, but `permission` is invisible to the transcript, so a wait cleared by
# mistake never comes back at all.
#
# `PermissionRequest` carries no `tool_use_id`, so the wait is keyed on the pair
# that it does carry: which agent asked and which tool it asked for. An absent
# `agent_id` is not "unknown" — it is how the session's own top-level agent
# looks, in every payload captured — so both sides being empty is a match, and
# only then. A wait with no tool recorded (one raised by `Notification`, or by
# an older version of this script) is never cleared here: `Stop` and
# `UserPromptSubmit` still clear it, and holding an orange indicator too long
# beats dropping it while the dialog is up.
if [ "$event" = "PostToolUse" ]; then
	case "$prev_state" in
	permission | question) ;;
	*) exit 0 ;;
	esac
	[ -z "$prev_wait_tool" ] && exit 0
	[ "$prev_wait_tool" = "$tool_name" ] || exit 0
	[ "$prev_wait_agent" = "$agent_id" ] || exit 0
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

tmp="$STATUS_DIR/.tmp.$session_id.$$"
"$JQ" -n \
	--argjson prev "$prev" \
	--arg sessionId "$session_id" \
	--arg cwd "$cwd" \
	--arg state "$state" \
	--arg event "$event" \
	--arg notificationType "$notif_type" \
	--arg message "$message" \
	--arg reason "$reason" \
	--arg transcript "$transcript" \
	--arg toolName "$tool_name" \
	--arg agentId "$agent_id" \
	--argjson ts "$(date +%s)" \
	'
	# A record older than the one already on disk is dropped: a delayed
	# UserPromptSubmit must not bury the Stop that overtook it. Emitting
	# nothing leaves the temporary file empty, and the caller keeps the
	# existing state.
	#
	# The types are checked before the comparison, and not only to be tidy:
	# in jq every number sorts before every string, so a `ts` of "abc" made
	# the comparison true forever and no state could ever be written again,
	# and a non-object `prev` such as `[1,2]` failed `.ts` outright, which
	# killed the whole program with the same result.
	if (($prev | type) == "object" and ($prev.ts | type) == "number" and $prev.ts > $ts)
	then empty else
	  # Notification payloads carry no cwd for some types; taking the empty
	  # string would blank out the path a previous event recorded.
	  {sessionId: $sessionId,
	   cwd: (if $cwd == "" then ($prev.cwd // "") else $cwd end),
	   state: $state,
	   event: $event,
	   ts: $ts}
	  # Who is waiting and for what, so that PostToolUse can tell its own tool
	  # from one belonging to a background subagent. A PermissionRequest opens
	  # a new wait and names it; any later event that keeps the state a wait
	  # (the Notification trailing six seconds behind, for one) has to carry
	  # the name along, or the wait left behind could never be cleared by the
	  # tool it belongs to. Anything that ends the wait drops both fields.
	  + (if $event == "PermissionRequest"
	     then (if $toolName == "" then {} else {waitTool: $toolName} end)
	          + (if $agentId == "" then {} else {waitAgent: $agentId} end)
	     elif $state == "permission" or $state == "question"
	     then (if ($prev.waitTool // "") == "" then {} else {waitTool: $prev.waitTool} end)
	          + (if ($prev.waitAgent // "") == "" then {} else {waitAgent: $prev.waitAgent} end)
	     else {} end)
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
