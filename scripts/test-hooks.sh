#!/bin/bash
# Tests for hooks/claude-window-status.sh — the state machine that decides what
# the panel shows for every chat — plus the debug-dump cap of hooks/statusline.sh
# at the very end.
#
# The hook is the riskiest artefact here: six events, three guards, and it runs
# inside every session the user has open, where a wrong answer is either a lost
# "answer me" signal or an orange indicator that never goes away. Everything
# below used to be checked by hand.
#
# Run: bash scripts/test-hooks.sh   (also wired into `make test`)
#
# No dependencies beyond jq, which the hook itself needs. Every case runs in a
# throwaway VSCODE_SWITCHER_STATUS_DIR, so the user's own state files are never
# touched.
set -u

# Inherited from the caller, this makes the hook drop a _debug.jsonl next to the
# state files, and the four cases that assert an empty status directory fail. The
# one case that wants the dump sets the variable itself.
unset VSCODE_SWITCHER_DEBUG

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="$REPO_DIR/hooks/claude-window-status.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vsw-hook-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if ! command -v jq >/dev/null 2>&1; then
	echo "jq is required to run these tests" >&2
	exit 1
fi

PASS=0
FAIL=0
CASE="(none)"

start() {
	CASE=$1
	rm -rf "$WORK/status"
	mkdir -p "$WORK/status"
	export VSCODE_SWITCHER_STATUS_DIR="$WORK/status"
}

fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $CASE"
	echo "      $1"
}

ok() { PASS=$((PASS + 1)); }

check() { # description actual expected
	if [ "$2" = "$3" ]; then ok; else fail "$1: got [$2], want [$3]"; fi
}

SESSION="11111111-2222-3333-4444-555555555555"
STATE_FILE() { echo "$VSCODE_SWITCHER_STATUS_DIR/${1:-$SESSION}.json"; }

# Feeds one payload to the hook. Every argument after the event name is a raw
# JSON fragment merged into the payload, so a case can add or drop any field.
send() { # json
	printf '%s' "$1" | bash "$HOOK"
}

payload() { # event [extra json fields...]
	local event=$1
	shift
	local extra=""
	for kv in "$@"; do extra="$extra,$kv"; done
	printf '{"session_id":"%s","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/project","hook_event_name":"%s"%s}' \
		"$SESSION" "$event" "$extra"
}

field() { # key [session]
	jq -r --arg k "$1" '.[$k] // ""' "$(STATE_FILE "${2:-}")" 2>/dev/null
}

state() { field state "${1:-}"; }

# The open waits as `tool/agent/state`, in order, so a case can say which ones
# survived an event without pulling the JSON apart itself.
waits() { # [session]
	jq -r '[(.waits // [])[] | "\(.tool)/\(.agent)/\(.state)"] | join(",")' \
		"$(STATE_FILE "${1:-}")" 2>/dev/null
}

# --- the six events -----------------------------------------------------------

start "UserPromptSubmit sets working"
send "$(payload UserPromptSubmit)"
check "state" "$(state)" "working"
check "cwd" "$(field cwd)" "/tmp/project"

start "Stop sets waiting"
send "$(payload Stop)"
check "state" "$(state)" "waiting"

start "PermissionRequest sets permission and records the wait"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
check "state" "$(state)" "permission"
check "waits" "$(waits)" "Bash//permission"

start "PermissionRequest for AskUserQuestion sets question"
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
check "state" "$(state)" "question"

start "PermissionRequest for ExitPlanMode sets question"
send "$(payload PermissionRequest '"tool_name":"ExitPlanMode"')"
check "state" "$(state)" "question"

start "SessionEnd removes the state and the metrics"
send "$(payload UserPromptSubmit)"
: >"$VSCODE_SWITCHER_STATUS_DIR/$SESSION.metrics.json"
send "$(payload SessionEnd '"reason":"clear"')"
check "state file gone" "$([ -e "$(STATE_FILE)" ] && echo present || echo gone)" "gone"
check "metrics gone" "$([ -e "$VSCODE_SWITCHER_STATUS_DIR/$SESSION.metrics.json" ] && echo present || echo gone)" "gone"

start "an unknown event is ignored"
send "$(payload PreToolUse '"tool_name":"Bash"')"
check "no file written" "$([ -e "$(STATE_FILE)" ] && echo present || echo absent)" "absent"

# --- Notification -------------------------------------------------------------

start "Notification idle_prompt sets waiting"
send "$(payload Notification '"notification_type":"idle_prompt"' '"message":"Claude is waiting for your input"')"
check "state" "$(state)" "waiting"

start "Notification permission_prompt sets permission"
send "$(payload Notification '"notification_type":"permission_prompt"' '"message":"Claude needs your permission"')"
check "state" "$(state)" "permission"

start "Notification with an unrelated type leaves the state alone"
send "$(payload Stop)"
send "$(payload Notification '"notification_type":"auth_success"' '"message":"Logged in"')"
check "state" "$(state)" "waiting"
check "event" "$(field event)" "Stop"

start "an unknown Notification type falls back to the message text"
send "$(payload Notification '"notification_type":"brand_new_thing"' '"message":"Claude needs your permission to run Bash"')"
check "state" "$(state)" "permission"

start "Notification never downgrades permission"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
send "$(payload Notification '"notification_type":"idle_prompt"' '"message":"Claude is waiting for your input"')"
check "state" "$(state)" "permission"

start "Notification never downgrades question"
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
send "$(payload Notification '"message":"Claude is waiting for your input"')"
check "state" "$(state)" "question"

start "Notification does not turn a question back into a permission"
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
send "$(payload Notification '"notification_type":"permission_prompt"' '"message":"Claude needs your permission"')"
check "state" "$(state)" "question"

start "a Notification that keeps the wait carries it along"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
send "$(payload Notification '"notification_type":"permission_prompt"' '"message":"Claude needs your permission"')"
check "state" "$(state)" "permission"
check "the wait survives" "$(waits)" "Bash//permission"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "and the tool can still clear it" "$(state)" "working"

start "a Notification without cwd keeps the recorded path"
send "$(payload UserPromptSubmit)"
printf '{"session_id":"%s","hook_event_name":"Notification","notification_type":"idle_prompt","message":"x"}' "$SESSION" | bash "$HOOK"
check "cwd" "$(field cwd)" "/tmp/project"

# --- PostToolUse: it clears its own wait and nobody else's --------------------

start "PostToolUse with nothing on disk writes nothing"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "no file written" "$([ -e "$(STATE_FILE)" ] && echo present || echo absent)" "absent"

start "PostToolUse does not resurrect a finished turn"
send "$(payload Stop)"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "state" "$(state)" "waiting"

start "PostToolUse clears the permission it was granted"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "state" "$(state)" "working"

start "PostToolUse clears the question it answered"
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
send "$(payload PostToolUse '"tool_name":"AskUserQuestion"')"
check "state" "$(state)" "working"

start "a background subagent does not clear the main agent question"
# The one caught in the wild: an AskUserQuestion dialog on screen while a
# subagent's Bash finished under the same session_id.
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"a39c3baec23"')"
check "state" "$(state)" "question"

start "the same tool run by another agent does not clear the wait"
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"aaaa1111"')"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"bbbb2222"')"
check "state" "$(state)" "permission"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"aaaa1111"')"
check "its own agent does clear it" "$(state)" "working"

start "a subagent clears its own wait, not the main agent one"
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"aaaa1111"')"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "main agent tool leaves it alone" "$(state)" "permission"

start "another tool of the same agent does not clear the wait"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
send "$(payload PostToolUse '"tool_name":"Read"')"
check "state" "$(state)" "permission"

# --- several waits at once ----------------------------------------------------

start "answering a subagent dialog leaves the main agent question standing"
# The whole point of keeping a list. The main agent asks a question, a subagent
# then raises a permission dialog of its own, and the subagent's dialog is
# answered first: the question is still on the user's screen and must still be
# the state of the row.
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"AAA"')"
check "the question outranks the newer permission" "$(state)" "question"
check "both waits are open" "$(waits)" "AskUserQuestion//question,Bash/AAA/permission"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"AAA"')"
check "state" "$(state)" "question"
check "only the question is left" "$(waits)" "AskUserQuestion//question"
send "$(payload PostToolUse '"tool_name":"AskUserQuestion"')"
check "answering it finally frees the row" "$(state)" "working"
check "no waits left" "$(waits)" ""

start "clearing a question falls back to the permission still open"
# The same in the other order: the state is the most urgent wait remaining, not
# the one that moved last.
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"AAA"')"
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
check "state" "$(state)" "question"
send "$(payload PostToolUse '"tool_name":"AskUserQuestion"')"
check "state" "$(state)" "permission"
check "waits" "$(waits)" "Bash/AAA/permission"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"AAA"')"
check "and then it is done" "$(state)" "working"

start "asking twice for the same tool is one wait"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
check "waits" "$(waits)" "Bash//permission"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "one PostToolUse clears it" "$(state)" "working"

start "Stop drops every open wait"
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"AAA"')"
send "$(payload Stop)"
check "state" "$(state)" "waiting"
check "waits" "$(waits)" ""

start "a wait raised by Notification does not hide the ones with names"
# Notification carries no tool name, so it can only keep the list it found.
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"AAA"')"
send "$(payload Notification '"notification_type":"permission_prompt"' '"message":"Claude needs your permission"')"
check "waits" "$(waits)" "Bash/AAA/permission"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"AAA"')"
check "state" "$(state)" "working"

# --- records written by older versions of the hook ----------------------------

start "a waitTool/waitAgent record from an older version still clears"
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"permission","event":"PermissionRequest","waitTool":"Bash","waitAgent":"aaaa1111","ts":1}' \
	"$SESSION" >"$(STATE_FILE)"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"bbbb2222"')"
check "another agent leaves it alone" "$(state)" "permission"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"aaaa1111"')"
check "its own agent clears it" "$(state)" "working"

start "a damaged waits list does not stick forever"
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"permission","event":"PermissionRequest","waits":"nonsense","ts":1}' \
	"$SESSION" >"$(STATE_FILE)"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "nothing to clear, so it holds" "$(state)" "permission"
send "$(payload Stop)"
check "Stop still takes it off" "$(state)" "waiting"

start "junk entries in the waits list are skipped, real ones are not"
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"permission","event":"PermissionRequest","waits":[null,7,{"agent":"x"},{"tool":"Bash","agent":"aaaa1111","state":"permission"}],"ts":1}' \
	"$SESSION" >"$(STATE_FILE)"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"aaaa1111"')"
check "state" "$(state)" "working"

start "a wait with no tool recorded is never cleared by PostToolUse"
# Raised by Notification, which carries no tool name; only Stop and
# UserPromptSubmit take it off.
send "$(payload Notification '"notification_type":"permission_prompt"' '"message":"Claude needs your permission"')"
check "no waitTool" "$(field waitTool)" ""
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "state" "$(state)" "permission"
send "$(payload Stop)"
check "Stop still clears it" "$(state)" "waiting"

start "a state file from an older version is not cleared by PostToolUse"
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"permission","event":"PermissionRequest","ts":1}' \
	"$SESSION" >"$(STATE_FILE)"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "state" "$(state)" "permission"
send "$(payload Stop)"
check "but it does not stick forever" "$(state)" "waiting"

start "PostToolUse works whatever the payload spacing"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
printf '{"session_id": "%s", "cwd": "/tmp/project", "hook_event_name": "PostToolUse", "tool_name": "Bash"}' "$SESSION" | bash "$HOOK"
check "state" "$(state)" "working"

start "an event name past the head window still takes the slow path"
# The fast path only looks at the first 2048 bytes; a payload that hides the
# event name behind a longer prefix has to stay correct, just slower.
send "$(payload PermissionRequest '"tool_name":"Bash"')"
pad=$(printf 'x%.0s' $(seq 1 4000))
printf '{"session_id":"%s","cwd":"/tmp/project","tool_input":{"command":"%s"},"hook_event_name":"PostToolUse","tool_name":"Bash"}' \
	"$SESSION" "$pad" | bash "$HOOK"
check "state" "$(state)" "working"

# --- out-of-order delivery and damaged input ---------------------------------

start "a record older than the one on disk is dropped"
send "$(payload Stop)"
future=$(($(date +%s) + 600))
jq --argjson ts "$future" '.ts = $ts' "$(STATE_FILE)" >"$WORK/tmp.json" && mv "$WORK/tmp.json" "$(STATE_FILE)"
send "$(payload UserPromptSubmit)"
check "state" "$(state)" "waiting"

start "a non-object state file does not block the write"
printf '[1,2]' >"$(STATE_FILE)"
send "$(payload Stop)"
check "state" "$(state)" "waiting"

start "a non-numeric ts does not block the write"
printf '{"sessionId":"%s","state":"working","ts":"abc"}' "$SESSION" >"$(STATE_FILE)"
send "$(payload Stop)"
check "state" "$(state)" "waiting"

start "a truncated state file does not block the write"
printf '{"sessionId":"%s","state":"work' "$SESSION" >"$(STATE_FILE)"
send "$(payload Stop)"
check "state" "$(state)" "waiting"

start "empty stdin is a no-op"
printf '' | bash "$HOOK"
check "exit code" "$?" "0"
check "nothing written" "$(ls "$VSCODE_SWITCHER_STATUS_DIR" | wc -l | tr -d ' ')" "0"

start "a payload that is not JSON is a no-op"
printf 'not json at all' | bash "$HOOK"
check "exit code" "$?" "0"
check "nothing written" "$(ls "$VSCODE_SWITCHER_STATUS_DIR" | wc -l | tr -d ' ')" "0"

start "a payload without session_id is a no-op"
printf '{"hook_event_name":"Stop","cwd":"/tmp/project"}' | bash "$HOOK"
check "nothing written" "$(ls "$VSCODE_SWITCHER_STATUS_DIR" | wc -l | tr -d ' ')" "0"

start "the message heuristic survives non-ASCII text"
# The script runs under LC_ALL=C, where `tr` folds ASCII and leaves every other
# byte alone — which is what a mixed-script notification needs.
send "$(payload Notification '"notification_type":"unknown_kind"' '"message":"Клод NEEDS YOUR PERMISSION пожалуйста"')"
check "state" "$(state)" "permission"
check "message" "$(field message)" "Клод NEEDS YOUR PERMISSION пожалуйста"

start "a non-ASCII cwd survives"
printf '{"session_id":"%s","cwd":"/Users/vvzvlad/Проекты/тест","hook_event_name":"Stop"}' "$SESSION" | bash "$HOOK"
check "cwd" "$(field cwd)" "/Users/vvzvlad/Проекты/тест"

start "a backslash in cwd is not doubled"
printf '{"session_id":"%s","cwd":"/tmp/a\\\\b","hook_event_name":"Stop"}' "$SESSION" | bash "$HOOK"
check "cwd" "$(field cwd)" '/tmp/a\b'

start "no temporary files are left behind"
send "$(payload UserPromptSubmit)"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
send "$(payload PostToolUse '"tool_name":"Bash"')"
send "$(payload Stop)"
check "leftovers" "$(ls -A "$VSCODE_SWITCHER_STATUS_DIR" | grep -c '^\.tmp\.' | tr -d ' ')" "0"

start "two sessions do not collide"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
other="99999999-8888-7777-6666-555555555555"
printf '{"session_id":"%s","cwd":"/tmp/other","hook_event_name":"Stop"}' "$other" | bash "$HOOK"
check "first session" "$(state)" "permission"
check "second session" "$(state "$other")" "waiting"

start "without jq the hook exits quietly"
# jq cannot be removed from the machine, so the copy under test is one with the
# lookup pointed at paths that do not exist.
NOJQ="$WORK/hook-nojq.sh"
sed -e 's#/opt/homebrew/bin/jq#/nonexistent/jq1#' \
	-e 's#/usr/local/bin/jq#/nonexistent/jq2#' \
	-e 's#/usr/bin/jq#/nonexistent/jq3#' "$HOOK" >"$NOJQ"
printf '%s' "$(payload Stop)" | PATH=/nonexistent /bin/bash "$NOJQ"
check "exit code" "$?" "0"
check "nothing written" "$(ls "$VSCODE_SWITCHER_STATUS_DIR" | wc -l | tr -d ' ')" "0"

# --- the debug dump ----------------------------------------------------------

start "the debug dump is capped"
export VSCODE_SWITCHER_DEBUG=1
dump="$VSCODE_SWITCHER_STATUS_DIR/_debug.jsonl"
send "$(payload Stop)"
check "dump written" "$([ -s "$dump" ] && echo yes || echo no)" "yes"
# One byte over the cap has to rotate rather than keep growing.
mkfile -n 5m "$dump" 2>/dev/null || dd if=/dev/zero of="$dump" bs=1m count=5 2>/dev/null
send "$(payload Stop)"
check "rotated" "$([ -s "$dump.1" ] && echo yes || echo no)" "yes"
check "fresh dump is small" "$([ "$(wc -c <"$dump")" -lt 4194304 ] && echo yes || echo no)" "yes"
unset VSCODE_SWITCHER_DEBUG

start "without VSCODE_SWITCHER_DEBUG nothing is dumped"
send "$(payload Stop)"
check "no dump" "$([ -e "$VSCODE_SWITCHER_STATUS_DIR/_debug.jsonl" ] && echo present || echo absent)" "absent"

start "the statusLine dump is capped too"
# The same cap on the other hook: it runs on every conversation update, so an
# uncapped append there grows just as fast.
export VSCODE_SWITCHER_DEBUG=1
dump="$VSCODE_SWITCHER_STATUS_DIR/_debug-statusline.jsonl"
printf '{"session_id":"%s","cwd":"/tmp/project"}' "$SESSION" | bash "$REPO_DIR/hooks/statusline.sh" >/dev/null
check "dump written" "$([ -s "$dump" ] && echo yes || echo no)" "yes"
mkfile -n 5m "$dump" 2>/dev/null || dd if=/dev/zero of="$dump" bs=1m count=5 2>/dev/null
printf '{"session_id":"%s","cwd":"/tmp/project"}' "$SESSION" | bash "$REPO_DIR/hooks/statusline.sh" >/dev/null
check "rotated" "$([ -s "$dump.1" ] && echo yes || echo no)" "yes"
check "fresh dump is small" "$([ "$(wc -c <"$dump")" -lt 4194304 ] && echo yes || echo no)" "yes"
unset VSCODE_SWITCHER_DEBUG

echo
echo "hook tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
