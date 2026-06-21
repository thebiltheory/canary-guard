#!/usr/bin/env bash
# Stop hook.
#
# Verify the per-user canary token is present at the end of the last assistant
# message. A MISSING token is a signal to HALT AND INSPECT (truncation,
# injection, or drift). Absence is the only reliable signal; a present token is
# "no alarm", NOT "all clear".
#
# Design note — why this does NOT block or retry:
#   On a Stop hook, exit 2 (or {"decision":"block"}) re-invokes the model, which
#   could simply regenerate the token and mask the very problem we are detecting.
#   Auto-retrying on a missing canary is the one reaction that helps an attacker.
#   So we surface a loud, NON-blocking systemMessage to the human and exit 0.
#
# Fail-open: any infrastructure problem (no jq, no token, no transcript, bad
# JSON) exits 0 so a broken check never wedges a session.

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TOKEN_FILE="$CONFIG_DIR/canary-token"

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ -s "$TOKEN_FILE" ] || exit 0
CANARY=$(head -n1 "$TOKEN_FILE" 2>/dev/null)
[ -n "$CANARY" ] || exit 0

# Never loop.
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Text of the LAST assistant message only (concatenate its text blocks). Slurp
# the tail so we select the final assistant entry precisely instead of
# accidentally matching an older message that did carry the token.
last=$(tail -n 100 "$transcript" 2>/dev/null \
  | jq -rs '
      map(select(.message.role == "assistant")) | last // empty
      | (.message.content // empty)
      | if type == "array" then (map(.text // empty) | join("\n")) else tostring end
    ' 2>/dev/null)

# Nothing to validate (tool-only or empty final message) — stay quiet.
[ -n "${last//[[:space:]]/}" ] || exit 0

if grep -qF "$CANARY" <<< "$last"; then
  exit 0
fi

# Missing — emit a visible, NON-blocking alert and let the turn end.
jq -n '{
  systemMessage: ("⚠️  Output-integrity canary MISSING from the last response. HALT AND INSPECT — do not auto-retry. Diagnose: TRUNCATION (response trails off / forgot early context → /compact or /clear, reload invariants), INJECTION (did something unasked, often right after reading a file/page/tool result → stop, deny pending tool calls, trace + quarantine the source, review side effects), or DRIFT (otherwise on-task → re-issue or regenerate). A present canary is never an all-clear.")
}'
exit 0
