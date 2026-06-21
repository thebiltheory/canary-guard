#!/usr/bin/env bash
# canary-cage.sh — animated status line for canary-guard.
#
#   integrity OK    -> a yellow canary hops & sings ♪ in its cage (~1 fps loop)
#   integrity DEAD  -> a red, fallen canary (x_x) with a flashing ⚠ alarm
#
# Health comes from canary-guard's hooks, which write "ok" / "dead" to
# $CLAUDE_CONFIG_DIR/canary-state (Stop after each turn; SessionStart revives it).
# If that file is absent (plugin not active yet) the canary is assumed healthy —
# absence of alarm is not an alarm.
#
# Enable via settings.json:
#   "statusLine": { "type": "command",
#                   "command": "~/.claude/scripts/canary-cage.sh",
#                   "refreshInterval": 1 }
#
# Claude Code re-runs this at most once per second, so the animation is a slow,
# deliberate hop — not smooth motion. Honors $PREFERS_REDUCED_MOTION (freezes it).

cat >/dev/null 2>&1   # drain the session JSON on stdin (unused here)

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_FILE="$CONFIG_DIR/canary-state"

state="ok"
[ -r "$STATE_FILE" ] && state="$(head -n1 "$STATE_FILE" 2>/dev/null)"
case "$state" in
  dead|missing|alarm) state="dead" ;;
  *)                  state="ok"   ;;
esac

# 1 fps frame index from the wall clock.
frame=$(( $(date +%s 2>/dev/null || echo 0) % 4 ))

# Reduced motion -> freeze on a stable frame.
case "${PREFERS_REDUCED_MOTION:-}" in
  1|true|TRUE|yes|on) frame=0 ;;
esac

YEL=$'\033[33m'; RED=$'\033[1;31m'; DIM=$'\033[2m'; RST=$'\033[0m'

if [ "$state" = "dead" ]; then
  # Dead: fallen bird, slow-flashing alarm.
  if [ $(( frame % 2 )) -eq 0 ]; then alarm="⚠ "; else alarm="  "; fi
  printf '%s💀 (| x_x |) %s%s%sintegrity broken%s\n' "$RED" "$alarm" "$RST" "$DIM" "$RST"
else
  # Alive: hop left/right, alternating note. Constant width (🐤 is 2 cols + 1 space).
  case "$frame" in
    1|3) bird="(| 🐤|)"; note="♫" ;;
    *)   bird="(|🐤 |)"; note="♪" ;;
  esac
  printf '%s%s %s%s %ssinging%s\n' "$YEL" "$note" "$bird" "$RST" "$DIM" "$RST"
fi
