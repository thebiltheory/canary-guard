#!/usr/bin/env bash
# Sanity check for the session-handoff logic (writes a handoff on a break, and
# the next session in the same project picks it up once).
#
#   tests/handoff-test.sh    # run it
#
# Exit code 0 = all green.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CFG=$(mktemp -d); export CLAUDE_CONFIG_DIR="$CFG"
WORK=$(mktemp -d); OTHER=$(mktemp -d); T=$(mktemp)
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
HD="$CFG/canary-handoff"
ctx_of(){ printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext'; }

{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"Build me a streaming CSV parser with backpressure"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ran an unexpected command; no token"}]}}'
} > "$T"

( cd "$WORK" && printf '{"session_id":"sess-123"}' | bash "$REPO/scripts/ensure-canary.sh" >/dev/null )
( cd "$WORK" && printf '{"transcript_path":"%s","stop_hook_active":false,"session_id":"sess-123"}' "$T" \
    | bash "$REPO/scripts/check-canary.sh" >/dev/null )

echo "[H1] break creates the handoff bundle"
[ -f "$HD/transcript.jsonl" ] && ok "full transcript preserved" || no "full transcript preserved"
[ -f "$HD/handoff.md" ] && ok "handoff.md written" || no "handoff.md written"
[ -f "$HD/PENDING" ] && ok "PENDING flag set" || no "PENDING flag set"
diff -q "$T" "$HD/transcript.jsonl" >/dev/null 2>&1 && ok "preserved transcript is byte-identical" || no "preserved transcript identical"

echo "[H2] PENDING scoped to the project cwd"
[ "$(head -n1 "$HD/PENDING")" = "$WORK" ] && ok "records WORK cwd" || no "records WORK cwd"

echo "[H3] handoff.md carries original prompt + pointer + warning + resume hint"
grep -q "backpressure" "$HD/handoff.md" && ok "original prompt captured" || no "original prompt captured"
grep -q "transcript.jsonl" "$HD/handoff.md" && ok "transcript pointer present" || no "transcript pointer present"
grep -qi "injection" "$HD/handoff.md" && ok "review warning present" || no "review warning present"
grep -q "claude --resume sess-123" "$HD/handoff.md" && ok "resume hint with session id" || no "resume hint"

echo "[H4] WRONG project: SessionStart does NOT consume or inject"
out=$( cd "$OTHER" && printf '{"session_id":"x"}' | bash "$REPO/scripts/ensure-canary.sh" )
[ -f "$HD/PENDING" ] && ok "handoff still pending elsewhere" || no "handoff still pending elsewhere"
case "$(ctx_of "$out")" in *RESUMING*) no "must not inject in other cwd";; *) ok "no injection in other cwd";; esac

echo "[H5] RIGHT project: SessionStart injects handoff + consumes flag"
out=$( cd "$WORK" && printf '{"session_id":"y"}' | bash "$REPO/scripts/ensure-canary.sh" )
case "$(ctx_of "$out")" in *RESUMING*) ok "handoff injected in correct cwd";; *) no "handoff injected";; esac
case "$(ctx_of "$out")" in *backpressure*) ok "injected context includes original prompt";; *) no "includes original prompt";; esac
case "$(ctx_of "$out")" in *"<<CANARY:"*) ok "still injects the canary instruction too";; *) no "still injects canary instruction";; esac
[ ! -f "$HD/PENDING" ] && ok "PENDING consumed (one-shot)" || no "PENDING consumed"

echo "[H6] subsequent session does NOT re-inject"
out=$( cd "$WORK" && printf '{"session_id":"z"}' | bash "$REPO/scripts/ensure-canary.sh" )
case "$(ctx_of "$out")" in *RESUMING*) no "must not re-inject";; *) ok "no re-injection after consume";; esac

echo "----------------------------------------"
printf 'HANDOFF: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$pass" "$fail"
rm -rf "$CFG" "$WORK" "$OTHER" "$T"
[ "$fail" -eq 0 ]
