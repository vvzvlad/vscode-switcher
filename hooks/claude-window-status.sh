#!/bin/bash
# Claude Code hook for VSCode Switcher.
#
# Reads a hook payload from stdin, derives a coarse agent state and writes it
# atomically to $STATUS_DIR/<session_id>.json. Installed for UserPromptSubmit,
# Stop, Notification and SessionEnd.
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

# Pull every field we might need in one pass. @tsv escapes embedded tabs and
# newlines, so the record stays on a single line whatever the payload contains.
# The tabs are then swapped for US (0x1f): tab counts as IFS whitespace, which
# would make `read` collapse runs of empty fields and shift the values.
fields=$(printf '%s' "$payload" | "$JQ" -r '
	def s: if . == null then "" elif type == "string" then . else tostring end;
	[
		((.session_id // .sessionId // "") | s),
		((.cwd // .workspace.current_dir // .workspace.project_dir // "") | s),
		((.hook_event_name // .hookEventName // "") | s),
		((.type // .notification_type // .notificationType // .subtype // "") | s),
		((.message // .notification // .title // "") | s),
		((.reason // .stop_reason // "") | s),
		((.transcript_path // .transcriptPath // "") | s)
	] | @tsv
' 2>/dev/null | tr '\t' '\037')
[ -z "$fields" ] && exit 0

IFS=$'\037' read -r session_id cwd event notif_type message reason transcript <<EOF
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
Notification)
	state=$(classify_notification)
	[ -z "$state" ] && exit 0
	;;
*)
	exit 0
	;;
esac

tmp="$STATUS_DIR/.tmp.$session_id.$$"
"$JQ" -n \
	--arg sessionId "$session_id" \
	--arg cwd "$cwd" \
	--arg state "$state" \
	--arg event "$event" \
	--arg notificationType "$notif_type" \
	--arg message "$message" \
	--arg reason "$reason" \
	--arg transcript "$transcript" \
	--argjson ts "$(date +%s)" \
	'{sessionId: $sessionId, cwd: $cwd, state: $state, event: $event, ts: $ts}
	 + (if $message == "" then {} else {message: $message} end)
	 + (if $notificationType == "" then {} else {notificationType: $notificationType} end)
	 + (if $reason == "" then {} else {reason: $reason} end)
	 + (if $transcript == "" then {} else {transcriptPath: $transcript} end)' \
	>"$tmp" 2>/dev/null

if [ -s "$tmp" ]; then
	mv -f "$tmp" "$target" 2>/dev/null
else
	rm -f "$tmp" 2>/dev/null
fi

exit 0
