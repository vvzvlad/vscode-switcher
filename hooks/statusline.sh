#!/bin/bash
# Claude Code statusLine command for VSCode Switcher.
#
# Claude invokes it on every conversation update and passes a JSON payload on
# stdin: model {id, display_name}, cost {total_cost_usd, ...} and
# context_window {total_input_tokens, context_window_size, used_percentage,
# remaining_percentage}. Note that the token count is total_input_tokens, not
# used_tokens, and that context_window_size states the real limit, so the
# 200k/1M window does not have to be guessed. Two things happen here:
#   1. a short status string is printed to stdout, which Claude renders below
#      the prompt;
#   2. the same numbers are cached in $STATUS_DIR/<session_id>.metrics.json so
#      the switcher can show context usage and the model without parsing a
#      multi-megabyte transcript.
#
# The metrics live in a separate file from the state written by
# claude-window-status.sh: both are updated at the same moments, and a shared
# file would let a stale statusLine invocation overwrite a fresh state.
#
# Debugging: VSCODE_SWITCHER_DEBUG=1 appends the raw stdin to
# $STATUS_DIR/_debug-statusline.jsonl. That file holds whole payloads, so it is
# opt-in and capped, exactly like the one the state hook writes.

STATUS_DIR="${VSCODE_SWITCHER_STATUS_DIR:-$HOME/.claude/window-status}"
DEBUG_MAX_BYTES=4194304

payload=$(cat 2>/dev/null)

mkdir -p "$STATUS_DIR" 2>/dev/null

# Capped exactly like the dump in claude-window-status.sh, and for the same
# reason: this runs on every conversation update in every open session, so an
# unbounded append grows without anyone watching it. One rotation at 4 MiB keeps
# the recent payloads and bounds the total at twice that.
if [ "${VSCODE_SWITCHER_DEBUG:-0}" = "1" ]; then
	debug_log="$STATUS_DIR/_debug-statusline.jsonl"
	debug_size=$(stat -f %z "$debug_log" 2>/dev/null || echo 0)
	if [ "${debug_size:-0}" -ge "$DEBUG_MAX_BYTES" ]; then
		mv -f "$debug_log" "$debug_log.1" 2>/dev/null
	fi
	printf '%s\n' "$payload" >>"$debug_log" 2>/dev/null
fi

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

# Not @tsv: it escapes backslashes too and nothing unescapes them again, so a
# cwd of `/a\b` would come back as `/a\\b`. Control characters are flattened
# instead, which is all the single-line record actually needs.
fields=$(printf '%s' "$payload" | "$JQ" -r '
	def s: (if . == null then "" elif type == "string" then . else tostring end)
		| gsub("[[:cntrl:]]"; " ");
	[
		((.session_id // .sessionId // "") | s),
		((.cwd // .workspace.current_dir // "") | s),
		((.model.display_name // .model.id // "") | s),
		((.model.id // "") | s),
		((.context_window.used_percentage // "") | s),
		((.context_window.total_input_tokens // .context_window.used_tokens // "") | s),
		((.cost.total_cost_usd // "") | s),
		((.context_window.context_window_size // "") | s)
	] | join([31] | implode)
' 2>/dev/null)
[ -z "$fields" ] && exit 0

# US (0x1f) rather than tab: tab is IFS whitespace, so `read` would collapse
# runs of empty fields and shift every value after the first missing one.
IFS=$'\037' read -r session_id cwd model_name model_id used_pct used_tokens cost window_size <<EOF
$fields
EOF

# Status string for the user. Fields that the payload did not provide are
# simply skipped rather than printed empty.
parts=""
[ -n "$model_name" ] && parts="$model_name"
if [ -n "$used_pct" ]; then
	pct=$(printf '%.0f' "$used_pct" 2>/dev/null)
	[ -n "$pct" ] && parts="${parts:+$parts | }ctx ${pct}%"
fi
if [ -n "$cost" ]; then
	usd=$(printf '%.2f' "$cost" 2>/dev/null)
	[ -n "$usd" ] && parts="${parts:+$parts | }\$$usd"
fi
printf '%s\n' "$parts"

[ -z "$session_id" ] && exit 0

tmp="$STATUS_DIR/.tmp.metrics.$session_id.$$"
"$JQ" -n \
	--arg sessionId "$session_id" \
	--arg cwd "$cwd" \
	--arg modelName "$model_name" \
	--arg modelId "$model_id" \
	--arg usedPercentage "$used_pct" \
	--arg usedTokens "$used_tokens" \
	--arg cost "$cost" \
	--arg windowSize "$window_size" \
	--argjson ts "$(date +%s)" \
	'{sessionId: $sessionId, cwd: $cwd, ts: $ts}
	 + (if $modelName == "" then {} else {modelName: $modelName} end)
	 + (if $modelId == "" then {} else {modelId: $modelId} end)
	 + (if $usedPercentage == "" then {} else {usedPercentage: ($usedPercentage | tonumber? // null)} end)
	 + (if $usedTokens == "" then {} else {usedTokens: ($usedTokens | tonumber? // null)} end)
	 + (if $windowSize == "" then {} else {contextWindowSize: ($windowSize | tonumber? // null)} end)
	 + (if $cost == "" then {} else {costUsd: ($cost | tonumber? // null)} end)' \
	>"$tmp" 2>/dev/null

if [ -s "$tmp" ]; then
	mv -f "$tmp" "$STATUS_DIR/$session_id.metrics.json" 2>/dev/null
else
	rm -f "$tmp" 2>/dev/null
fi

exit 0
