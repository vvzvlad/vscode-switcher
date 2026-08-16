#!/bin/bash
# Idempotent installer for the VSCode Switcher hooks.
#
#   scripts/install-hooks.sh              install / refresh
#   scripts/install-hooks.sh --uninstall  remove only our entries
#
# The user's ~/.claude/settings.json is shared with other tools (it already
# carries two SessionStart blocks), so the script never rewrites it wholesale:
# it removes exactly the entries whose command points at this repository's
# hooks directory, adds the current ones back, validates the result and only
# then replaces the file. A timestamped backup is taken first.
set -u

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
HOOKS_DIR="$REPO_DIR/hooks"
MARKER="$HOOKS_DIR/"

MODE="install"
DEBUG="0"
for arg in "$@"; do
	case "$arg" in
	--uninstall) MODE="uninstall" ;;
	--debug) DEBUG="1" ;;
	--help | -h)
		sed -n '2,12p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		echo "unknown argument: $arg" >&2
		exit 2
		;;
	esac
done

if ! command -v jq >/dev/null 2>&1; then
	echo "jq is required but was not found in PATH" >&2
	exit 1
fi

STATE_HOOK="$HOOKS_DIR/claude-window-status.sh"
STATUSLINE_HOOK="$HOOKS_DIR/statusline.sh"

if [ "$MODE" = "install" ]; then
	for f in "$STATE_HOOK" "$STATUSLINE_HOOK"; do
		if [ ! -f "$f" ]; then
			echo "missing hook script: $f" >&2
			exit 1
		fi
		chmod +x "$f"
	done
fi

mkdir -p "$(dirname "$SETTINGS")" "$HOME/.claude/window-status"

# settings.json is very often a symlink into a dotfiles repository. The write
# below is `mv`, which would replace the link with a regular file and quietly
# detach the settings from that repository, so the link is followed first.
if [ -L "$SETTINGS" ]; then
	RESOLVED=$(readlink -f "$SETTINGS" 2>/dev/null)
	if [ -n "$RESOLVED" ]; then
		echo "note: $SETTINGS is a symlink, writing through it to $RESOLVED"
		SETTINGS="$RESOLVED"
	fi
fi

if [ -f "$SETTINGS" ]; then
	if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
		echo "$SETTINGS is not valid JSON, refusing to touch it" >&2
		exit 1
	fi
	# The pid keeps two runs within the same second from overwriting each
	# other's backup, which would destroy the pristine copy.
	BACKUP="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S).$$"
	cp -p "$SETTINGS" "$BACKUP"
	echo "backup: $BACKUP"
	# Claude allows exactly one statusLine, so installing ours destroys anyone
	# else's. That is recoverable from the backup, but only if it is said out
	# loud.
	EXISTING_STATUSLINE=$(jq -r '.statusLine.command // ""' "$SETTINGS")
	case "$MODE:$EXISTING_STATUSLINE" in
	install:"" | install:*"$MARKER"*) ;;
	install:*)
		echo "warning: replacing an existing statusLine that is not ours:" >&2
		echo "  $EXISTING_STATUSLINE" >&2
		echo "  restore it from the backup above if you still need it" >&2
		;;
	esac
else
	echo '{}' >"$SETTINGS"
	echo "created: $SETTINGS"
fi

# With --debug the hooks dump their raw stdin next to the state files, which is
# how the payload schema gets verified on a real machine.
PREFIX=""
[ "$DEBUG" = "1" ] && PREFIX="VSCODE_SWITCHER_DEBUG=1 "

ADDITIONS=$(jq -n \
	--arg state "$PREFIX$STATE_HOOK" \
	'
	def entry($cmd): {hooks: [{type: "command", command: $cmd, async: true, timeout: 5}]};
	{
		UserPromptSubmit: [entry($state)],
		PermissionRequest: [entry($state)],
		PostToolUse: [entry($state)],
		# PostToolUse fires only when the call succeeded; a failed one arrives
		# as PostToolUseFailure, and without it the wait of a tool that
		# errored out stays open until the turn ends (SPEC §2.6.3).
		PostToolUseFailure: [entry($state)],
		Stop: [entry($state)],
		Notification: [entry($state)],
		SessionEnd: [entry($state)]
	}')

TMP="$SETTINGS.tmp.$$"
jq \
	--arg marker "$MARKER" \
	--arg statusline "$PREFIX$STATUSLINE_HOOK" \
	--arg mode "$MODE" \
	--argjson additions "$ADDITIONS" \
	'
	# Drop every hook entry whose command points at our hooks directory, then
	# drop groups and event keys that became empty. Foreign entries (such as
	# the two existing SessionStart blocks) are left untouched.
	#
	#
	# A group whose "hooks" is missing or is not an array is foreign data we do
	# not understand: it is passed through untouched and never dropped.
	# Iterating that null used to abort the whole run with a jq message that
	# pointed nowhere near the real problem.
	def clean_group:
		if (.hooks | type) == "array"
		then .hooks |= map(select(((.command // "") | contains($marker)) | not))
		else .
		end;
	def is_left_empty:
		(.hooks | type) == "array" and (.hooks | length) == 0;

	def strip_ours:
		with_entries(.value |= (map(clean_group) | map(select(is_left_empty | not))))
		| with_entries(select(((.value // []) | length) > 0));

	(.hooks // {} | strip_ours) as $clean
	| (if $mode == "install"
	   then reduce ($additions | to_entries[]) as $e
	        ($clean; .[$e.key] = ((.[$e.key] // []) + $e.value))
	   else $clean
	   end) as $hooks
	| .hooks = $hooks
	| (if $mode == "install"
	   then .statusLine = {type: "command", command: $statusline, padding: 0}
	   else (if ((.statusLine.command // "") | contains($marker)) then del(.statusLine) else . end)
	   end)
	| (if (.hooks | length) == 0 then del(.hooks) else . end)
	' "$SETTINGS" >"$TMP"

if [ ! -s "$TMP" ] || ! jq -e . "$TMP" >/dev/null 2>&1; then
	rm -f "$TMP"
	echo "generated settings are not valid JSON, aborting; $SETTINGS unchanged" >&2
	exit 1
fi

mv -f "$TMP" "$SETTINGS"

if [ "$MODE" = "install" ]; then
	echo "installed hooks: UserPromptSubmit, PermissionRequest, PostToolUse, PostToolUseFailure, Stop, Notification, SessionEnd -> $STATE_HOOK"
	echo "installed statusLine -> $STATUSLINE_HOOK"
else
	echo "removed VSCode Switcher hooks and statusLine from $SETTINGS"
fi
echo "hook events in settings: $(jq -r '(.hooks // {}) | keys | join(", ")' "$SETTINGS")"
