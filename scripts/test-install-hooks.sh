#!/bin/bash
# Tests for scripts/install-hooks.sh — the installer that edits the user's
# ~/.claude/settings.json.
#
# The real settings file is never under test. Every case runs with HOME pointed
# at a throwaway directory (the installer also does a
# `mkdir -p "$HOME/.claude/window-status"`) and CLAUDE_SETTINGS inside it too.
# `run` refuses to start the installer unless both paths are inside the sandbox
# (an empty SETTINGS would fall back to the real file); a later case asserts each
# redirection, and the last one compares the real file's `cksum`.
#
# One write leaves the sandbox: install mode does `chmod +x` on the repository's
# hook scripts, which are already tracked 755.
#
# Run: bash scripts/test-install-hooks.sh   (also wired into `make test`)
#
# No dependencies beyond jq, which the installer itself requires.
set -u

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$REPO_DIR/scripts/install-hooks.sh"
STATE_HOOK="$REPO_DIR/hooks/claude-window-status.sh"
STATUSLINE_HOOK="$REPO_DIR/hooks/statusline.sh"
MARKER="$REPO_DIR/hooks/"

# Captured before anything below can move HOME.
REAL_SETTINGS="$HOME/.claude/settings.json"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vsw-install-tests.XXXXXX")
# One case needs a directory *outside* `$WORK` — that is the whole point of it —
# so the trap has to carry that one too, or an exit between its creation and its
# removal would leave it behind in the system temp directory. Empty until the
# case creates it, and removing it twice is harmless.
OUTSIDE=""
trap 'rm -rf "$WORK" ${OUTSIDE:+"$OUTSIDE"}' EXIT

if ! command -v jq >/dev/null 2>&1; then
	echo "jq is required to run these tests" >&2
	exit 1
fi

# `cksum` of a missing file prints nothing and fails, and the fallback string
# compares just as well — the point is only that the answer is the same after.
real_state() { cksum "$REAL_SETTINGS" 2>/dev/null || echo "absent"; }
REAL_BEFORE=$(real_state)

PASS=0
FAIL=0
CASE="(none)"

fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $CASE"
	echo "      $1"
}

ok() { PASS=$((PASS + 1)); }

check() { # description actual expected
	if [ "$2" = "$3" ]; then ok; else fail "$1: got [$2], want [$3]"; fi
}

# A fresh throwaway HOME per case. Everything the installer writes — the
# settings file, its timestamped backup, the window-status directory — lands
# under it, so nothing has to be cleaned up between cases.
SANDBOX=""
SETTINGS=""
start() { # description [initial settings json]
	CASE=$1
	SANDBOX=$(mktemp -d "$WORK/box.XXXXXX")
	export HOME="$SANDBOX"
	SETTINGS="$SANDBOX/settings.json"
	[ $# -gt 1 ] && printf '%s' "$2" >"$SETTINGS"
	return 0
}

run() { # installer args...
	# Both paths must sit under the throwaway root before the installer runs: an
	# empty SETTINGS makes the installer fall back to the user's own file.
	# Two separate cases, because one glob over "$SETTINGS:$HOME" would mis-split
	# on a colon inside either value.
	case "$SETTINGS" in
	"$WORK"/*) ;;
	*)
		echo "sandbox escape: SETTINGS=[$SETTINGS] not under $WORK" >&2
		exit 1
		;;
	esac
	case "$HOME" in
	"$WORK"/*) ;;
	*)
		echo "sandbox escape: HOME=[$HOME] not under $WORK" >&2
		exit 1
		;;
	esac
	CLAUDE_SETTINGS="$SETTINGS" bash "$INSTALLER" "$@" >"$SANDBOX/out" 2>&1
}

# Every entry installed under our marker, as `<event> <command>`, sorted — the
# uninstall assertions want "none of ours", and the idempotence one wants "the
# same set twice".
ours() {
	jq -r --arg m "$MARKER" '
		(.hooks // {}) | to_entries[] | .key as $k
		| .value[]? | (.hooks // [])[]?
		| select((.command // "") | contains($m))
		| "\($k) \(.command)"' "$SETTINGS" 2>/dev/null | sort
}

# A settings file that is not ours: two foreign hooks — one on an event we do
# not install, one sharing an event key with us — a foreign statusLine, and two
# top-level keys that have nothing to do with hooks.
FOREIGN='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/other/greet.sh"}]}],
	"PostToolUse":[{"hooks":[{"type":"command","command":"/opt/other/audit.sh"}]}]},
	"statusLine":{"type":"command","command":"/opt/other/line.sh"},
	"permissions":{"allow":["Bash(ls:*)"]},"model":"opus"}'

# --- the sandbox itself -------------------------------------------------------

start "the guard refuses to run the installer outside the sandbox"
# Checks an escaped SETTINGS and an escaped HOME separately. The escape points at
# another throwaway directory. `run` creates `$SANDBOX/out` only as it launches
# the installer, so an absent `out` proves the guard fired first. `run` exits
# its shell, hence the subshell.
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/vsw-outside.XXXXXX")
sandboxed=$SETTINGS
SETTINGS="$OUTSIDE/settings.json"
(run) >/dev/null 2>&1
rc=$?
check "an escaped SETTINGS is refused" "$rc" "1"
check "nothing was written there" "$([ -e "$SETTINGS" ] && echo present || echo absent)" "absent"
check "and the installer never started" \
	"$([ -e "$SANDBOX/out" ] && echo present || echo absent)" "absent"
SETTINGS=$sandboxed
# On a clean slate, or the second half would inherit the first one's verdict:
# both use the same `$SANDBOX/out` as their evidence that nothing was launched.
rm -f "$SANDBOX/out"
export HOME="$OUTSIDE"
(run) >/dev/null 2>&1
rc=$?
check "an escaped HOME is refused too" "$rc" "1"
check "no status directory was made there" \
	"$([ -e "$OUTSIDE/.claude" ] && echo present || echo absent)" "absent"
check "the settings file was not written either" \
	"$([ -e "$SETTINGS" ] && echo present || echo absent)" "absent"
check "and the installer never started" \
	"$([ -e "$SANDBOX/out" ] && echo present || echo absent)" "absent"
export HOME="$SANDBOX"
rm -rf "$OUTSIDE"

start "the installer writes inside the sandbox and nowhere else"
# The named file getting written proves CLAUDE_SETTINGS is honoured, the
# untouched default under HOME proves it was not ignored, and window-status
# proves HOME took effect for the write that does not go through the variable.
run
check "the file CLAUDE_SETTINGS named was written" "$([ -s "$SETTINGS" ] && echo yes || echo no)" "yes"
check "the default path under HOME was left alone" "$([ -e "$SANDBOX/.claude/settings.json" ] && echo present || echo absent)" "absent"
check "HOME took effect for the status directory" "$([ -d "$SANDBOX/.claude/window-status" ] && echo yes || echo no)" "yes"
check "the real settings are untouched" "$(real_state)" "$REAL_BEFORE"

# --- installing ---------------------------------------------------------------

start "install registers every event, PostToolUseFailure included"
run
rc=$?
check "exit code" "$rc" "0"
check "event keys" "$(jq -r '.hooks | keys | join(",")' "$SETTINGS")" \
	"Notification,PermissionRequest,PostToolUse,PostToolUseFailure,SessionEnd,Stop,UserPromptSubmit"
check "the newest key points at the state hook" \
	"$(jq -r '.hooks.PostToolUseFailure[0].hooks[0].command' "$SETTINGS")" "$STATE_HOOK"
check "and is configured like the rest" \
	"$(jq -c '.hooks.PostToolUseFailure[0].hooks[0] | [.type, .async, .timeout]' "$SETTINGS")" \
	'["command",true,5]'
check "statusLine" "$(jq -r '.statusLine.command' "$SETTINGS")" "$STATUSLINE_HOOK"
check "and the event list is echoed back" \
	"$(grep -c 'PostToolUseFailure' "$SANDBOX/out")" "2"

start "a second install does not duplicate what the first one wrote"
run
once=$(ours)
run
check "the same entries, once each" "$(ours)" "$once"
check "one group per event key" \
	"$(jq -r '[.hooks[] | length] | unique | map(tostring) | join(",")' "$SETTINGS")" "1"
check "one command per group" \
	"$(jq -r '[.hooks[][] | .hooks | length] | unique | map(tostring) | join(",")' "$SETTINGS")" "1"

# --- uninstalling -------------------------------------------------------------

start "--uninstall takes every entry of ours back out"
run
run --uninstall
check "nothing of ours is left" "$(ours)" ""
check "the empty hooks key is dropped with them" "$(jq -r 'has("hooks")' "$SETTINGS")" "false"
check "and our statusLine goes too" "$(jq -r 'has("statusLine")' "$SETTINGS")" "false"

# --- somebody else's settings -------------------------------------------------

start "a foreign hook survives both install and uninstall" "$FOREIGN"
run
check "a foreign event key is untouched" \
	"$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$SETTINGS")" "/opt/other/greet.sh"
check "so is a foreign entry on an event we install" \
	"$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$SETTINGS")" "/opt/other/audit.sh"
check "ours was appended next to it" \
	"$(jq -r '.hooks.PostToolUse[1].hooks[0].command' "$SETTINGS")" "$STATE_HOOK"
run --uninstall
check "the foreign event key is still there" \
	"$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$SETTINGS")" "/opt/other/greet.sh"
check "and so is the foreign entry we sat next to" \
	"$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$SETTINGS")" "/opt/other/audit.sh"
check "while nothing of ours is left" "$(ours)" ""

start "settings that are not hooks are carried through" "$FOREIGN"
run
check "permissions" "$(jq -c '.permissions' "$SETTINGS")" '{"allow":["Bash(ls:*)"]}'
check "model" "$(jq -r '.model' "$SETTINGS")" "opus"
run --uninstall
check "permissions after uninstall" "$(jq -c '.permissions' "$SETTINGS")" '{"allow":["Bash(ls:*)"]}'
check "model after uninstall" "$(jq -r '.model' "$SETTINGS")" "opus"

start "replacing a foreign statusLine is said out loud and backed up" "$FOREIGN"
# Claude allows exactly one statusLine, so installing ours destroys anyone
# else's. That is recoverable from the backup — but only if both the warning and
# the backup are actually there.
run
check "warned" "$(grep -c 'replacing an existing statusLine' "$SANDBOX/out")" "1"
check "the old command is named" "$(grep -c '/opt/other/line.sh' "$SANDBOX/out")" "1"
backup=$(ls "$SANDBOX"/settings.json.bak.* 2>/dev/null | head -1)
check "a backup was taken" "$([ -s "$backup" ] && echo yes || echo no)" "yes"
check "and it still holds the foreign statusLine" \
	"$(jq -r '.statusLine.command' "$backup" 2>/dev/null)" "/opt/other/line.sh"

start "invalid JSON is refused instead of overwritten" "not json at all"
run
rc=$?
check "exit code" "$rc" "1"
check "the file is left exactly as it was" "$(cat "$SETTINGS")" "not json at all"

# --- the file this must never have touched ------------------------------------

start "the user's own settings file was never written"
check "checksum" "$(real_state)" "$REAL_BEFORE"

echo
echo "installer tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
