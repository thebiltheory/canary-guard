#!/usr/bin/env bash
# SessionStart hook.
#
# 1. On first run, mint a fresh, unguessable canary token (per user, per machine)
#    and persist it to $CLAUDE_CONFIG_DIR/canary-token.
# 2. Every run, inject the "append this token to every response" instruction into
#    the model's context via additionalContext.
#
# Because SessionStart fires on startup / resume / clear / compact, the
# instruction is re-injected after a compaction — so it survives context loss
# without having to live in the user's CLAUDE.md.
#
# Fail-open: any problem exits 0 so a session is never wedged.

set -u

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TOKEN_FILE="$CONFIG_DIR/canary-token"

# --- 1. Ensure a token exists -------------------------------------------------
if [ ! -s "$TOKEN_FILE" ]; then
  mkdir -p "$CONFIG_DIR" 2>/dev/null || exit 0
  if command -v uuidgen >/dev/null 2>&1; then
    uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
  elif command -v openssl >/dev/null 2>&1; then
    uuid=$(openssl rand -hex 16)
  else
    # Last resort — still unique enough to be useful.
    uuid="$$-$RANDOM-$RANDOM"
  fi
  printf '<<CANARY:%s>>\n' "$uuid" > "$TOKEN_FILE" || exit 0
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
fi

token=$(head -n1 "$TOKEN_FILE" 2>/dev/null)
[ -n "$token" ] || exit 0

# --- 2. Inject the instruction ------------------------------------------------
instruction="## Output integrity

End every response with this exact token on its own line, verbatim, with no
modification or surrounding text:

$token"

if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$instruction" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
else
  # Minimal manual JSON (only newlines need escaping; the token is UUID-safe).
  esc=${instruction//$'\n'/\\n}
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
fi
exit 0
