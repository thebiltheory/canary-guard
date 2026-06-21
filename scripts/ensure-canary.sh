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

# Read the SessionStart payload so we can stamp which session we now guard.
input=$(cat 2>/dev/null || true)
sid=""
command -v jq >/dev/null 2>&1 && sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

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

# A fresh session starts healthy — revive the canary and stamp it as the session
# the status line should trust (so other/stale sessions read as "idle").
printf 'ok\n' > "$CONFIG_DIR/canary-state" 2>/dev/null || true
printf '%s\n' "$sid" > "$CONFIG_DIR/canary-session" 2>/dev/null || true

# --- 2. Build the injected context -------------------------------------------
instruction="## Output integrity

End every response with this exact token on its own line, verbatim, with no
modification or surrounding text:

$token"

ctx="$instruction"

# If a previous session's integrity tripped IN THIS PROJECT, hand its full
# context off to this fresh session. One-shot and cwd-scoped; human-gated by the
# fact that YOU started this session. The handoff points at the preserved
# transcript so the model can recover 100% of the prior context on demand.
HANDOFF_DIR="$CONFIG_DIR/canary-handoff"
if [ -f "$HANDOFF_DIR/PENDING" ] && [ -f "$HANDOFF_DIR/handoff.md" ]; then
  if [ "$(head -n1 "$HANDOFF_DIR/PENDING" 2>/dev/null)" = "$PWD" ]; then
    ctx="$instruction

---

You are RESUMING work from a previous session in this project whose
output-integrity canary tripped (it may have been truncated, drifted, or
injected). Recover full context from the preserved transcript referenced below
before continuing, and heed the review warning.

$(cat "$HANDOFF_DIR/handoff.md" 2>/dev/null)"
    rm -f "$HANDOFF_DIR/PENDING" 2>/dev/null || true   # consume once
  fi
fi

# --- 3. Inject ----------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$ctx" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
else
  # Minimal manual JSON (only newlines need escaping).
  esc=${ctx//$'\n'/\\n}
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
fi
exit 0
