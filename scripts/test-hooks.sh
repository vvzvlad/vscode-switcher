#!/bin/bash
# Tests for hooks/claude-window-status.sh — the state machine that decides what
# the panel shows for every chat — plus the debug-dump cap of hooks/statusline.sh
# at the very end.
#
# A wrong answer from the hook is either a lost "answer me" signal or an orange
# indicator that never goes away.
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

# Whether the key is there at all. `waits` above returns the empty string for
# three different records — no file, no key, `waits: []` — so "nothing is
# waiting" and "the key is gone" have to be asserted separately: SPEC §2.6 says
# the key exists only while at least one wait is open.
has_waits() { # [session]
	jq -r 'has("waits")' "$(STATE_FILE "${1:-}")" 2>/dev/null
}

# --- the seven events ---------------------------------------------------------

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

# --- PostToolUseFailure: a call that failed ends its wait just the same -------
#
# PostToolUse fires only after a *successful* call; a failed one (including an
# MCP tool that returned an error result) arrives as PostToolUseFailure
# (SPEC §2.6.2). It must behave exactly like PostToolUse.

start "PostToolUseFailure clears the permission it was granted"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
check "the wait is open" "$(waits)" "Bash//permission"
send "$(payload PostToolUseFailure '"tool_name":"Bash"' '"error":"Exit code 7"' '"is_interrupt":false')"
check "state" "$(state)" "working"
check "no waits left" "$(waits)" ""
check "and the key itself is gone" "$(has_waits)" "false"

start "PostToolUseFailure with nothing on disk writes nothing"
send "$(payload PostToolUseFailure '"tool_name":"Bash"' '"error":"Exit code 7"')"
check "no file written" "$([ -e "$(STATE_FILE)" ] && echo present || echo absent)" "absent"

start "PostToolUseFailure does not clear somebody else's wait"
# The whole record is compared, not just the state: a wait that belongs to
# another agent must leave the file untouched, `ts` included.
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"aaaa1111"')"
untouched=$(jq -c . "$(STATE_FILE)")
send "$(payload PostToolUseFailure '"tool_name":"Bash"' '"agent_id":"bbbb2222"' '"error":"Exit code 7"')"
check "another agent changes nothing" "$(jq -c . "$(STATE_FILE)")" "$untouched"
send "$(payload PostToolUseFailure '"tool_name":"Read"' '"agent_id":"aaaa1111"' '"error":"File not found"')"
check "another tool changes nothing" "$(jq -c . "$(STATE_FILE)")" "$untouched"
send "$(payload PostToolUseFailure '"tool_name":"Bash"' '"agent_id":"aaaa1111"' '"error":"Exit code 7"')"
check "its own pair does clear it" "$(state)" "working"

start "PostToolUseFailure does not resurrect a finished turn"
# Measured on 2.1.233: a subagent's PostToolUseFailure landed 3.7 s after the
# parent's Stop. What keeps it from turning an answered chat back into a working
# one is that Stop empties the wait list, so the pair matches nothing; here the
# payload never gets that far, because the fast path reads `waiting` off disk and
# leaves before jq.
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"ad625ae3cf3"')"
send "$(payload Stop)"
send "$(payload PostToolUseFailure '"tool_name":"Bash"' '"agent_id":"ad625ae3cf3"' '"error":"Exit code 7"')"
check "state" "$(state)" "waiting"
check "event" "$(field event)" "Stop"

start "a finished turn survives a failed call that missed the fast path"
# The same sequence with the fast path taken out of it: the event name is pushed
# past the 2048-byte head window, so the payload reaches the state machine and
# the pair check is all that is left. The record is the real one Stop wrote, not
# one built here — Stop is what emptied the list, and that is the whole reason
# there is no pair to match.
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"ad625ae3cf3"')"
send "$(payload Stop)"
pad=$(printf 'x%.0s' $(seq 1 4000))
printf '{"session_id":"%s","cwd":"/tmp/project","tool_input":{"command":"%s"},"hook_event_name":"PostToolUseFailure","tool_name":"Bash","agent_id":"ad625ae3cf3","error":"Exit code 7"}' \
	"$SESSION" "$pad" | bash "$HOOK"
check "nothing is rewritten" "$(field event)" "Stop"
check "state" "$(state)" "waiting"

start "the state of a record never disagrees with the waits it carries"
# The state written is the worst of the list, so a non-empty list only ever
# appears next to `permission` or `question`. The post-tool path relies on this
# to need only the pair check, with no guard on the previous state (SPEC §2.6.3).
broken=""
held=0
step() { # payload fragments
	send "$(payload "$@")"
	[ -e "$(STATE_FILE)" ] || return 0
	local s w
	s=$(state)
	w=$(waits)
	[ -z "$w" ] || held=$((held + 1))
	case "$s" in
	permission | question) ;;
	*) [ -z "$w" ] || broken="$broken [$s carries $w]" ;;
	esac
}
step UserPromptSubmit
step PermissionRequest '"tool_name":"Bash"'
step PermissionRequest '"tool_name":"AskUserQuestion"'
step PermissionRequest '"tool_name":"Grep"' '"agent_id":"AAA"'
step Notification '"notification_type":"permission_prompt"' '"message":"Claude needs your permission"'
step Notification '"notification_type":"idle_prompt"' '"message":"Claude is waiting for your input"'
step PostToolUse '"tool_name":"AskUserQuestion"'
step PostToolUseFailure '"tool_name":"Grep"' '"agent_id":"AAA"' '"error":"Exit code 1"'
step PostToolUseFailure '"tool_name":"Bash"' '"error":"Exit code 7"'
step Stop
step UserPromptSubmit
step PermissionRequest '"tool_name":"ExitPlanMode"'
step Stop
check "records that broke it" "$broken" ""
# Without this the case would pass just as well on a battery that never opened a
# wait at all — an invariant nothing ever tested against is not pinned.
check "steps that left a wait standing" "$held" "8"

start "a failed subagent call leaves the main agent question standing"
send "$(payload PermissionRequest '"tool_name":"AskUserQuestion"')"
send "$(payload PermissionRequest '"tool_name":"mcp__probe__statusIsError"' '"agent_id":"AAA"')"
check "both waits are open" "$(waits)" "AskUserQuestion//question,mcp__probe__statusIsError/AAA/permission"
send "$(payload PostToolUseFailure '"tool_name":"mcp__probe__statusIsError"' '"agent_id":"AAA"' '"error":"MCP error 403"')"
check "only the question is left" "$(waits)" "AskUserQuestion//question"
check "and it is the state of the row" "$(state)" "question"

start "PostToolUseFailure works whatever the payload spacing"
# The fast path matches a literal string in the payload, so both spellings the
# CLI could emit have to reach the state machine.
send "$(payload PermissionRequest '"tool_name":"Bash"')"
printf '{"session_id": "%s", "cwd": "/tmp/project", "hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "error": "Exit code 7"}' "$SESSION" | bash "$HOOK"
check "with spaces" "$(state)" "working"
send "$(payload PermissionRequest '"tool_name":"Bash"')"
printf '{"session_id":"%s","cwd":"/tmp/project","hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"Exit code 7"}' "$SESSION" | bash "$HOOK"
check "and without" "$(state)" "working"

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
check "and the key itself is gone" "$(has_waits)" "false"

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
check "and the key itself is gone" "$(has_waits)" "false"

start "a wait raised by Notification does not hide the ones with names"
# Notification carries no tool name, so it can only keep the list it found.
send "$(payload PermissionRequest '"tool_name":"Bash"' '"agent_id":"AAA"')"
send "$(payload Notification '"notification_type":"permission_prompt"' '"message":"Claude needs your permission"')"
check "waits" "$(waits)" "Bash/AAA/permission"
send "$(payload PostToolUse '"tool_name":"Bash"' '"agent_id":"AAA"')"
check "state" "$(state)" "working"

start "the new list is computed from the file as it is at write time"
# Two PostToolUse from different subagents finish within milliseconds of each
# other routinely, and if both computed their new list from the copy each read on
# the way in, the second to write would resurrect the wait the first had cleared
# (SPEC §2.6.3). So the writer re-reads the file instead of reusing that copy.
#
# Checked without depending on timing: `date` is called while the writer's
# arguments are being built, which is exactly the window between the two reads,
# so a `date` on PATH that rewrites the state file stands in for the other hook
# finishing first. The wait it adds meanwhile has to survive.
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"permission","event":"PermissionRequest","waits":[{"tool":"Bash","agent":"","state":"permission"}],"ts":1}' \
	"$SESSION" >"$(STATE_FILE)"
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"question","event":"PermissionRequest","waits":[{"tool":"Bash","agent":"","state":"permission"},{"tool":"AskUserQuestion","agent":"","state":"question"}],"ts":1}' \
	"$SESSION" >"$WORK/meanwhile.json"
fakebin="$WORK/fakebin"
mkdir -p "$fakebin"
{
	printf '#!/bin/bash\n'
	printf 'cp %s %s\n' "$WORK/meanwhile.json" "$(STATE_FILE)"
	printf 'exec %s "$@"\n' "$(command -v date)"
} >"$fakebin/date"
chmod +x "$fakebin/date"
printf '%s' "$(payload PostToolUse '"tool_name":"Bash"')" | PATH="$fakebin:$PATH" bash "$HOOK"
rm -rf "$fakebin"
check "the wait raised meanwhile survives" "$(waits)" "AskUserQuestion//question"
check "and it is the state of the row" "$(state)" "question"

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

start "a waits list does not confuse the fast path"
# The early exit matches `"state": "permission"` over the whole file, and that
# string sits inside every element of `waits` too, so it can match on a record
# whose top-level state is something else entirely. By the invariant above no
# such record exists — the top-level state is the maximum over the list, and the
# key is left out while the list is empty — so this one is built by hand to
# exercise the match itself. All a hit here buys is the slow path: the record is
# handed to the state machine, which decides on the pair alone. Nothing about
# the row changes, `working` in and `working` out; a real wait must still pass.
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"working","event":"UserPromptSubmit","waits":[{"tool":"Bash","agent":"","state":"permission"}],"ts":1}' \
	"$SESSION" >"$(STATE_FILE)"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "a nested permission does not revive a finished turn" "$(state)" "working"
check "and the match did let it through to the slow path" "$(field event)" "PostToolUse"
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"permission","event":"PermissionRequest","waits":[{"tool":"Bash","agent":"","state":"permission"}],"ts":1}' \
	"$SESSION" >"$(STATE_FILE)"
send "$(payload PostToolUse '"tool_name":"Bash"')"
check "a real wait still goes through" "$(state)" "working"

start "an event name past the head window still takes the slow path"
# The fast path only looks at the first 2048 bytes; a payload that hides the
# event name behind a longer prefix has to stay correct, just slower.
send "$(payload PermissionRequest '"tool_name":"Bash"')"
pad=$(printf 'x%.0s' $(seq 1 4000))
printf '{"session_id":"%s","cwd":"/tmp/project","tool_input":{"command":"%s"},"hook_event_name":"PostToolUse","tool_name":"Bash"}' \
	"$SESSION" "$pad" | bash "$HOOK"
check "state" "$(state)" "working"

start "the post-tool events leave before the dump is written"
# A typo in the `case $head` patterns would silently send every post-tool event
# down the slow path. Each name appears there twice, with and without a space
# after the colon (the CLI's exact spelling is unverified), so both spellings
# are written out literally here; `payload` only produces the unspaced one.
#
# The dump is appended after the exit, so its absence proves the exit ran; the
# final `Stop` (no fast path) shows the dump would otherwise appear. Nothing is
# on disk here, so the exit taken is the `[ -s "$probe" ]` one.
export VSCODE_SWITCHER_DEBUG=1
dump="$VSCODE_SWITCHER_STATUS_DIR/_debug.jsonl"
# Every pattern is asserted on a clean slate: all four share one dump file, so
# without the removal a later check would inherit an earlier one's verdict and
# several would go red for a single missing pattern.
left_before_dump() { # payload
	rm -f "$dump"
	printf '%s' "$1" | bash "$HOOK"
	[ -e "$dump" ] && echo present || echo absent
}
check "PostToolUse, no space after the colon" \
	"$(left_before_dump "$(printf '{"session_id":"%s","cwd":"/tmp/project","hook_event_name":"PostToolUse","tool_name":"Bash"}' "$SESSION")")" \
	"absent"
check "PostToolUse, with one" \
	"$(left_before_dump "$(printf '{"session_id": "%s", "cwd": "/tmp/project", "hook_event_name": "PostToolUse", "tool_name": "Bash"}' "$SESSION")")" \
	"absent"
check "PostToolUseFailure, no space after the colon" \
	"$(left_before_dump "$(printf '{"session_id":"%s","cwd":"/tmp/project","hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"Exit code 7"}' "$SESSION")")" \
	"absent"
check "PostToolUseFailure, with one" \
	"$(left_before_dump "$(printf '{"session_id": "%s", "cwd": "/tmp/project", "hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "error": "Exit code 7"}' "$SESSION")")" \
	"absent"
check "an event without a fast path is dumped" \
	"$(left_before_dump "$(payload Stop)")" "present"
unset VSCODE_SWITCHER_DEBUG

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

start "a whole record with junk after it does not block the write"
# The nastiest of the damaged shapes, because it half-parses: jq prints the
# object *and* exits non-zero, while `--slurpfile` on the same file is fatal. A
# hook that went by the printed object alone would write nothing — and, the file
# being unchanged and still half-parsing, would write nothing on every later
# event either, freezing the record until SessionEnd with an orange indicator
# that no Stop could take off.
printf '{"sessionId":"%s","cwd":"/tmp/project","state":"permission","event":"PermissionRequest","waits":[{"tool":"Bash","agent":"","state":"permission"}],"ts":1} JUNK' \
	"$SESSION" >"$(STATE_FILE)"
send "$(payload Stop)"
check "state" "$(state)" "waiting"
check "and the stale wait is gone with it" "$(has_waits)" "false"

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
