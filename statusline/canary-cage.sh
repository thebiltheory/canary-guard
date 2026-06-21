#!/usr/bin/env bash
# canary-cage.sh — honest animated status line for canary-guard.
#
#   guarding + OK    -> a yellow canary hops & sings ♪ (~1 fps loop)
#   guarding + DEAD  -> a red, fallen canary (x_x) with a flashing ⚠ alarm
#   not guarding     -> a dim, perched canary marked "idle" (no health claim)
#
# "Guarding" = canary-guard's hooks are validating THIS session. SessionStart
# stamps the active session id into $CLAUDE_CONFIG_DIR/canary-session and writes
# canary-state=ok; Stop updates canary-state to ok/dead. This script only shows a
# health verdict when the session id Claude Code hands it on stdin matches the
# stamped one — otherwise it honestly shows "idle" instead of a borrowed/stale
# verdict. (If a Claude Code build doesn't pass a session id, it falls back to
# the last recorded state.)
#
# Honors $PREFERS_REDUCED_MOTION (freezes the loop).

input=$(cat 2>/dev/null)

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_FILE="$CONFIG_DIR/canary-state"
SESSION_FILE="$CONFIG_DIR/canary-session"

sid=""
command -v jq >/dev/null 2>&1 && sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
guard=$(head -n1 "$SESSION_FILE" 2>/dev/null)
state=$(head -n1 "$STATE_FILE" 2>/dev/null)

# Decide what we may honestly claim.
mode=idle
if [ -n "$sid" ]; then
  # We know our own session id: trust the verdict only if WE are the guarded one.
  if [ -n "$guard" ] && [ "$sid" = "$guard" ]; then
    case "$state" in dead|missing|alarm) mode=dead ;; ok) mode=ok ;; esac
  fi
else
  # No session id on stdin (older Claude Code): fall back to the recorded state.
  case "$state" in dead|missing|alarm) mode=dead ;; ok) mode=ok ;; esac
fi

frame=$(( $(date +%s 2>/dev/null || echo 0) % 4 ))
case "${PREFERS_REDUCED_MOTION:-}" in 1|true|TRUE|yes|on) frame=0 ;; esac

YEL=$'\033[33m'; RED=$'\033[1;31m'; DIM=$'\033[2m'; RST=$'\033[0m'

case "$mode" in
  dead)
    # The canary is still a yellow bird — only the cage, skull and alarm go red.
    if [ $(( frame % 2 )) -eq 0 ]; then warn="${RED}⚠${RST}"; else warn="${DIM}⚠${RST}"; fi
    printf '%s💀%s %s(|%s %sx_x%s %s|)%s %s %sintegrity broken%s\n' \
      "$RED" "$RST" "$RED" "$RST" "$YEL" "$RST" "$RED" "$RST" "$warn" "$DIM" "$RST"
    ;;
  ok)
    # Alive: hop left/right, alternating note. Constant width.
    case "$frame" in
      1|3) bird="(| 🐤|)"; note="♫" ;;
      *)   bird="(|🐤 |)"; note="♪" ;;
    esac
    printf '%s%s %s%s %ssinging%s\n' "$YEL" "$note" "$bird" "$RST" "$DIM" "$RST"
    ;;
  *)
    # idle — not guarding this session; make NO health claim.
    printf '%s· (|🐤 |) idle%s\n' "$DIM" "$RST"
    ;;
esac
