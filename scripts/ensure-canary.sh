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
sid=""; source=""; tp=""
if command -v jq >/dev/null 2>&1; then
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  source=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)
  tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
fi

# Optional verification log — enabled by creating $CONFIG_DIR/canary-debug.
dlog() {
  [ -e "$CONFIG_DIR/canary-debug" ] || return 0
  printf '%s  %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$*" >> "$CONFIG_DIR/canary-debug.log" 2>/dev/null || true
}

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

# A fresh session starts healthy. Record health PER SESSION (keyed by this
# session's transcript) so concurrent sessions don't fight over a single flag and
# an idle session keeps its own verdict instead of getting stuck on "idle".
printf 'ok\n' > "$CONFIG_DIR/canary-state" 2>/dev/null || true   # global fallback
if [ -n "$tp" ]; then
  mkdir -p "$CONFIG_DIR/canary-sessions" 2>/dev/null || true
  printf 'ok\n' > "$CONFIG_DIR/canary-sessions/$(basename "$tp")" 2>/dev/null || true
fi
# Prune stale per-session files so the directory stays small.
find "$CONFIG_DIR/canary-sessions" -type f -mtime +7 -delete 2>/dev/null || true

# Verification switch: canary-test-drift suppresses token injection so the model
# genuinely never emits it → the next Stop sees a REAL break (to exercise the
# alarm + handoff end-to-end, triggered from OUTSIDE the conversation).
if [ -e "$CONFIG_DIR/canary-test-drift" ]; then
  dlog "SessionStart source=$source sid=$sid  TEST-DRIFT active -> token injection SUPPRESSED"
  exit 0
fi

# --- 2. Build the injected context -------------------------------------------
instruction="## Output integrity

End every response with this exact token on its own line, verbatim, with no
modification or surrounding text:

$token"

ctx="$instruction"
ho="no"

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
    ho="yes"
  fi
fi

dlog "SessionStart source=$source sid=$sid  injected rule (handoff=$ho)"

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
