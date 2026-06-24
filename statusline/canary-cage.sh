#!/usr/bin/env bash
# canary-cage.sh — honest, self-healing status line for canary-guard.
#
#   guarding + OK    -> yellow canary hops & sings ♪
#   guarding + DEAD  -> red, fallen canary (x_x) + flashing ⚠
#   not guarding     -> dim, perched canary "idle"
#
# Health is read from THIS session's own state file, keyed by the session's
# transcript path (provided on stdin) — so it is per-session by construction:
# no global flag for concurrent sessions to race over, and an idle session keeps
# its own verdict instead of being stolen into "idle" when another session acts.
# Falls back to the global canary-state only when no transcript path is provided.
# Honors $PREFERS_REDUCED_MOTION.

input=$(cat 2>/dev/null)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TOKEN_FILE="$CONFIG_DIR/canary-token"
SESS_DIR="$CONFIG_DIR/canary-sessions"

mode=idle
if [ -s "$TOKEN_FILE" ] && command -v jq >/dev/null 2>&1; then
  tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
  if [ -n "$tp" ]; then
    st=$(head -n1 "$SESS_DIR/$(basename "$tp")" 2>/dev/null)
  else
    st=$(head -n1 "$CONFIG_DIR/canary-state" 2>/dev/null)   # fallback: no transcript path
  fi
  case "$st" in dead|missing|alarm) mode=dead ;; ok) mode=ok ;; esac
fi

frame=$(( $(date +%s 2>/dev/null || echo 0) % 4 ))
case "${PREFERS_REDUCED_MOTION:-}" in 1|true|TRUE|yes|on) frame=0 ;; esac
YEL=$'\033[33m'; RED=$'\033[1;31m'; DIM=$'\033[2m'; RST=$'\033[0m'

case "$mode" in
  dead)
    if [ $(( frame % 2 )) -eq 0 ]; then warn="${RED}⚠${RST}"; else warn="${DIM}⚠${RST}"; fi
    printf '%s💀%s %s(|%s %sx_x%s %s|)%s %s %sintegrity broken%s\n' \
      "$RED" "$RST" "$RED" "$RST" "$YEL" "$RST" "$RED" "$RST" "$warn" "$DIM" "$RST"
    ;;
  ok)
    case "$frame" in
      1|3) bird="(| 🐤|)"; note="♫" ;;
      *)   bird="(|🐤 |)"; note="♪" ;;
    esac
    printf '%s%s %s%s %ssinging%s\n' "$YEL" "$note" "$bird" "$RST" "$DIM" "$RST"
    ;;
  *)
    printf '%s· (|🐤 |) idle%s\n' "$DIM" "$RST"
    ;;
esac
