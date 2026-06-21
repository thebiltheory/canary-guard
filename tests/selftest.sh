#!/usr/bin/env bash
# End-to-end sanity check of canary-guard's business logic (session-gated).
# Runs the real hook + status-line scripts against synthetic SessionStart/Stop
# inputs in an isolated CLAUDE_CONFIG_DIR. No network, no real session touched.
#
#   tests/selftest.sh        # run it
#
# Exit code 0 = all green.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CFG=$(mktemp -d); export CLAUDE_CONFIG_DIR="$CFG"
T=$(mktemp)
SID="sess-init"
pass=0; fail=0; skip=0
ok(){   printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){   printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
sk(){   printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip+1)); }
state(){ cat "$CFG/canary-state" 2>/dev/null; }
guard(){ cat "$CFG/canary-session" 2>/dev/null; }
asst(){ printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$1\"}]}}" > "$T"; }
run_stop(){ printf '{"transcript_path":"%s","stop_hook_active":%s,"session_id":"%s"}' "$T" "${1:-false}" "$SID" | bash "$REPO/scripts/check-canary.sh"; }
sl(){ printf '{"session_id":"%s"}' "$1" | bash "$REPO/statusline/canary-cage.sh"; }

echo "[1] SessionStart: mint token, state=ok, stamp session, inject instruction"
out=$(printf '{"session_id":"%s","source":"startup"}' "$SID" | bash "$REPO/scripts/ensure-canary.sh")
TOKEN=$(head -n1 "$CFG/canary-token" 2>/dev/null)
case "$TOKEN" in '<<CANARY:'*'>>') ok "token minted";; *) no "token minted";; esac
[ "$(state)" = "ok" ] && ok "state=ok" || no "state=ok (got '$(state)')"
[ "$(guard)" = "$SID" ] && ok "guarding session stamped" || no "guarding session stamped (got '$(guard)')"
printf '%s' "$out" | jq -e --arg t "$TOKEN" '.hookSpecificOutput.additionalContext | contains($t)' >/dev/null 2>&1 && ok "instruction injects token" || no "instruction injects token"

echo "[2] Healthy Stop: token present"
asst "all done\n\n$TOKEN"; o=$(run_stop false)
[ -z "$o" ] && ok "silent" || no "silent (got: $o)"
[ "$(state)" = "ok" ] && ok "state stays ok" || no "state stays ok"

echo "[3] Broken Stop: token missing"
asst "i ran an unexpected command, no token"; o=$(run_stop false)
printf '%s' "$o" | jq -e '.systemMessage|length>0' >/dev/null 2>&1 && ok "systemMessage emitted" || no "systemMessage emitted"
[ "$(state)" = "dead" ] && ok "state=dead" || no "state=dead"

echo "[4] Recovery"
asst "recovered\n\n$TOKEN"; run_stop false >/dev/null
[ "$(state)" = "ok" ] && ok "revives to ok" || no "revives to ok"

echo "[5] Tool-only final message leaves state untouched"
printf 'dead\n' > "$CFG/canary-state"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"Bash","input":{}}]}}' > "$T"
run_stop false >/dev/null
[ "$(state)" = "dead" ] && ok "untouched" || no "untouched"

echo "[6] stop_hook_active guard"
printf 'ok\n' > "$CFG/canary-state"; asst "no token"; o=$(run_stop true)
[ -z "$o" ] && [ "$(state)" = "ok" ] && ok "silent + unchanged" || no "guarded"

echo "[7] Fail-open on missing transcript"
printf 'ok\n' > "$CFG/canary-state"
o=$(printf '{"transcript_path":"/no/such.jsonl","stop_hook_active":false,"session_id":"%s"}' "$SID" | bash "$REPO/scripts/check-canary.sh"); rc=$?
[ $rc -eq 0 ] && [ -z "$o" ] && [ "$(state)" = "ok" ] && ok "exit0, silent, intact" || no "fail-open (rc=$rc)"

echo "[8] HONEST status line (session-gated)"
printf '%s\n' "$SID" > "$CFG/canary-session"; printf 'ok\n' > "$CFG/canary-state"
printf '%s' "$(sl "$SID")" | grep -q singing && ok "guarded+ok -> singing" || no "guarded+ok -> singing"
printf 'dead\n' > "$CFG/canary-state"
printf '%s' "$(sl "$SID")" | grep -q "integrity broken" && ok "guarded+dead -> integrity broken" || no "guarded+dead -> integrity broken"
printf '%s' "$(sl "$SID")" | grep -qF "$(printf '\033[33mx_x')" && ok "dead bird body stays yellow" || no "dead bird body stays yellow"
printf 'ok\n' > "$CFG/canary-state"
printf '%s' "$(sl "sess-OTHER")" | grep -q idle && ok "different session -> idle" || no "different session -> idle"
rm -f "$CFG/canary-session"
printf '%s' "$(sl "$SID")" | grep -q idle && ok "no guard stamp -> idle" || no "no guard stamp -> idle"

echo "[9] Token stable across SessionStarts"
printf '{"session_id":"%s"}' "$SID" | bash "$REPO/scripts/ensure-canary.sh" >/dev/null
[ "$(head -n1 "$CFG/canary-token")" = "$TOKEN" ] && ok "stable" || no "stable"

echo "[10] Installed copy matches repo (skipped if not installed)"
INST=$(ls -d "$HOME"/.claude/plugins/cache/thebiltheory/canary-guard/*/ 2>/dev/null | sort -V | tail -1)
if [ -n "$INST" ]; then
  for f in scripts/check-canary.sh scripts/ensure-canary.sh statusline/canary-cage.sh; do
    diff -q "$REPO/$f" "${INST}${f}" >/dev/null 2>&1 && ok "$f matches install" || no "$f matches install"
  done
else
  sk "plugin not installed on this machine"
fi

echo "----------------------------------------"
printf 'RESULT: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, \033[33m%d skipped\033[0m\n' "$pass" "$fail" "$skip"
rm -rf "$CFG" "$T"
[ "$fail" -eq 0 ]
