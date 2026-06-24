#!/usr/bin/env bash
# End-to-end sanity check of canary-guard's business logic (per-session state,
# end-token check, per-turn reinforcement, verification mode). Runs the real
# scripts against synthetic SessionStart / UserPromptSubmit / Stop payloads in an
# isolated CLAUDE_CONFIG_DIR. No network; your real ~/.claude is never touched.
#
#   tests/selftest.sh        # exit 0 = all green
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CFG=$(mktemp -d); export CLAUDE_CONFIG_DIR="$CFG"
T=$(mktemp); SID="sess-init"
pass=0; fail=0; skip=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
sk(){ printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip+1)); }
state(){ cat "$CFG/canary-state" 2>/dev/null; }                       # global fallback record
psess(){ cat "$CFG/canary-sessions/$(basename "$1")" 2>/dev/null; }    # per-session, by transcript
asst(){ printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$1\"}]}}" > "$T"; }
asst_ok(){ asst "$1\n\n$TOKEN"; }
run_stop(){ printf '{"transcript_path":"%s","stop_hook_active":%s,"session_id":"%s"}' "$T" "${1:-false}" "$SID" | bash "$REPO/scripts/check-canary.sh"; }
slt(){ printf '{"transcript_path":"%s"}' "$1" | bash "$REPO/statusline/canary-cage.sh"; }

echo "[1] SessionStart: mint token, record per-session ok, inject rule"
TP1="$CFG/init.jsonl"; : > "$TP1"
out=$(printf '{"session_id":"%s","source":"startup","transcript_path":"%s"}' "$SID" "$TP1" | bash "$REPO/scripts/ensure-canary.sh")
TOKEN=$(head -n1 "$CFG/canary-token" 2>/dev/null)
case "$TOKEN" in '<<CANARY:'*'>>') ok "token minted";; *) no "token minted";; esac
[ "$(psess "$TP1")" = "ok" ] && ok "per-session health recorded (keyed by transcript)" || no "per-session health recorded"
printf '%s' "$out" | jq -e --arg t "$TOKEN" '.hookSpecificOutput.additionalContext | contains($t)' >/dev/null 2>&1 && ok "instruction injects token" || no "instruction injects token"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("End every response")' >/dev/null 2>&1 && ok "rule is end-of-response" || no "rule is end-of-response"

echo "[R] UserPromptSubmit reinforcement re-injects the rule + token"
r=$(printf '{"prompt":"hello"}' | bash "$REPO/scripts/reinforce-canary.sh")
printf '%s' "$r" | jq -e --arg t "$TOKEN" '.hookSpecificOutput.additionalContext | contains($t)' >/dev/null 2>&1 && ok "reinforcement injects token" || no "reinforcement injects token"
printf '%s' "$r" | jq -e '.hookSpecificOutput.additionalContext | test("end your reply")' >/dev/null 2>&1 && ok "reinforcement restates the rule" || no "reinforcement restates rule"

echo "[2] Healthy Stop: token present"
asst_ok "all done"; o=$(run_stop false)
[ -z "$o" ] && ok "silent" || no "silent (got: $o)"
[ "$(psess "$T")" = "ok" ] && ok "this session recorded ok" || no "this session recorded ok"

echo "[3] Broken Stop: token missing"
asst "i answered but left off the token"; o=$(run_stop false)
printf '%s' "$o" | jq -e '.systemMessage | test("MISSING")' >/dev/null 2>&1 && ok "systemMessage emitted" || no "systemMessage emitted"
[ "$(psess "$T")" = "dead" ] && ok "this session recorded dead" || no "this session recorded dead"

echo "[4] Recovery"
asst_ok "recovered"; run_stop false >/dev/null
[ "$(psess "$T")" = "ok" ] && ok "revives to ok" || no "revives to ok"

echo "[5] Tool-only final message leaves state untouched"
printf 'dead\n' > "$CFG/canary-sessions/$(basename "$T")"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"Bash","input":{}}]}}' > "$T"
run_stop false >/dev/null
[ "$(psess "$T")" = "dead" ] && ok "untouched" || no "untouched"

echo "[6] stop_hook_active guard"
printf 'ok\n' > "$CFG/canary-sessions/$(basename "$T")"; asst "no token"; o=$(run_stop true)
[ -z "$o" ] && [ "$(psess "$T")" = "ok" ] && ok "silent + unchanged" || no "guarded"

echo "[7] Fail-open on missing transcript"
o=$(printf '{"transcript_path":"/no/such.jsonl","stop_hook_active":false,"session_id":"%s"}' "$SID" | bash "$REPO/scripts/check-canary.sh"); rc=$?
[ $rc -eq 0 ] && [ -z "$o" ] && ok "exit0, silent" || no "fail-open (rc=$rc)"

echo "[8] HONEST per-session status line (transcript-keyed)"
TPA="$CFG/sessA.jsonl"; TPB="$CFG/sessB.jsonl"; : > "$TPA"; : > "$TPB"
printf 'ok\n' > "$CFG/canary-sessions/$(basename "$TPA")"
printf '%s' "$(slt "$TPA")" | grep -q singing && ok "ok -> singing" || no "ok -> singing"
printf 'dead\n' > "$CFG/canary-sessions/$(basename "$TPA")"
printf '%s' "$(slt "$TPA")" | grep -q "integrity broken" && ok "dead -> integrity broken" || no "dead -> integrity broken"
printf '%s' "$(slt "$TPA")" | grep -qF "$(printf '\033[33mx_x')" && ok "dead bird body stays yellow" || no "dead bird body stays yellow"
printf '%s' "$(slt "$TPB")" | grep -q idle && ok "session with no state -> idle" || no "session with no state -> idle"
# THE BUG FIX: an active session B going dead must NOT drag idle session A into idle/dead
printf 'ok\n'   > "$CFG/canary-sessions/$(basename "$TPA")"
printf 'dead\n' > "$CFG/canary-sessions/$(basename "$TPB")"
printf '%s' "$(slt "$TPA")" | grep -q singing && ok "idle session A unaffected by active session B (sticky-idle bug fixed)" || no "session A unaffected by B"
# no transcript path -> fall back to global canary-state
printf 'dead\n' > "$CFG/canary-state"
printf '%s' "$(printf '{}' | bash "$REPO/statusline/canary-cage.sh")" | grep -q "integrity broken" && ok "no transcript -> fallback to canary-state" || no "fallback to canary-state"

echo "[9] Token stable across SessionStarts"
printf '{"session_id":"%s","transcript_path":"%s"}' "$SID" "$TP1" | bash "$REPO/scripts/ensure-canary.sh" >/dev/null
[ "$(head -n1 "$CFG/canary-token")" = "$TOKEN" ] && ok "stable" || no "stable"

echo "[V] Verification mode: debug log + test-drift switch"
touch "$CFG/canary-debug"
printf '{"session_id":"%s","source":"resume","transcript_path":"%s"}' "$SID" "$TP1" | bash "$REPO/scripts/ensure-canary.sh" >/dev/null
printf '{"prompt":"x"}' | bash "$REPO/scripts/reinforce-canary.sh" >/dev/null
grep -q "SessionStart" "$CFG/canary-debug.log" 2>/dev/null && ok "debug log records SessionStart firing" || no "debug log records SessionStart"
grep -q "UserPromptSubmit" "$CFG/canary-debug.log" 2>/dev/null && ok "debug log records UserPromptSubmit firing" || no "debug log records UserPromptSubmit"
touch "$CFG/canary-test-drift"
od=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$SID" "$TP1" | bash "$REPO/scripts/ensure-canary.sh")
[ -z "$od" ] && ok "test-drift: SessionStart suppresses token injection" || no "test-drift: suppresses injection (got: $od)"
rd=$(printf '{"prompt":"x"}' | bash "$REPO/scripts/reinforce-canary.sh")
[ -z "$rd" ] && ok "test-drift: reinforcement suppressed" || no "test-drift: reinforcement suppressed (got: $rd)"
rm -f "$CFG/canary-debug" "$CFG/canary-test-drift" "$CFG/canary-debug.log"

echo "[10] Installed copy matches repo (skipped if not installed)"
INST=$(ls -d "$HOME"/.claude/plugins/cache/thebiltheory/canary-guard/*/ 2>/dev/null | sort -V | tail -1)
if [ -n "$INST" ]; then
  for f in scripts/check-canary.sh scripts/ensure-canary.sh scripts/reinforce-canary.sh statusline/canary-cage.sh; do
    diff -q "$REPO/$f" "${INST}${f}" >/dev/null 2>&1 && ok "$f matches install" || no "$f matches install"
  done
else
  sk "plugin not installed on this machine"
fi

echo "----------------------------------------"
printf 'RESULT: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, \033[33m%d skipped\033[0m\n' "$pass" "$fail" "$skip"
rm -rf "$CFG" "$T"
[ "$fail" -eq 0 ]
