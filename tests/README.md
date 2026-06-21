# tests

Self-contained sanity checks for canary-guard. They run the real hook and
status-line scripts against synthetic SessionStart/Stop payloads inside a
throwaway `CLAUDE_CONFIG_DIR` — no network, and your real `~/.claude` is never
touched.

```bash
tests/selftest.sh        # token mint, state machine, honest status line, fail-open
tests/handoff-test.sh    # break -> handoff bundle -> cwd-scoped one-shot pickup
```

Each exits `0` when green. `selftest.sh` also diffs the repo scripts against the
installed plugin copy when present (skips that check otherwise).

Requires `bash` and `jq`.
