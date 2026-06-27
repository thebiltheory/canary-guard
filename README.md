# 🐤 canary-guard

```text
        .--------------.
        |   __         |
        |  <o )___     |   ♪
        |   \ <_  )    |       canary-guard
        |    `----'    |
        |   __||__     |   a tripwire for your model's
        '--------------'   output integrity
            |      |
       ======'======'=====

   live:   ♪ (|🐤 |) singing       💀 (| x_x |) integrity broken       · (|🐤 |) idle
```

![license: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)
![Claude Code plugin](https://img.shields.io/badge/Claude_Code-plugin-d97757?style=flat-square&logo=anthropic)
![canary: singing](https://img.shields.io/badge/canary-singing-f6c453?style=flat-square)

> **The model sings a secret word at the end of every reply.**
> **When it goes quiet, something broke.**

A Claude Code plugin that adds an **output-integrity canary** to every session.

The model is instructed to end every response with a unique, unguessable token.
A `Stop` hook checks for it. If the token goes **missing**, you get a signal that
something broke: truncation, prompt injection, or drift.

> **Read this first — the core asymmetry.** The canary only proves integrity by
> its **absence**. A missing token reliably means *something is wrong*. A present
> token does **not** mean everything is fine — a capable prompt injection can keep
> emitting the token while still misbehaving. Treat a present canary as
> **"no alarm," not "all clear."** When a response looks wrong, trust the behavior
> over the token.

This is **one signal among several**, not a complete defense. For the more common
interactive risk — untrusted content reaching the model through tool results (a
fetched page, a dependency README, a file written by another process) — a
`PreToolUse` hook that inspects or gates tool calls usually does more than an
output canary.

## How it works

Three hooks, a small shared state file, and an optional status line:

| Hook | Script | What it does |
|---|---|---|
| `SessionStart` | `scripts/ensure-canary.sh` | Mints a per-user/per-machine UUID token into `$CLAUDE_CONFIG_DIR/canary-token` on first run; every run injects the "end every response with this token" rule via `additionalContext`, records this session's health as `ok` (keyed by its transcript), and replays any pending handoff for this project (see *Continuity*). |
| `UserPromptSubmit` | `scripts/reinforce-canary.sh` | Re-injects the rule on every turn so it stays recent and compliance doesn't decay as the session grows (recency reinforcement — re-reading the rule, not just re-emitting a nonce). |
| `Stop` | `scripts/check-canary.sh` | Checks the last assistant message for the token. Present → records this session `ok`. Missing → records `dead`, captures a handoff bundle (see *Continuity*), and emits a non-blocking warning. |

Shared files under `$CLAUDE_CONFIG_DIR`: **`canary-token`** (the secret),
**`canary-sessions/`** (per-session `ok`/`dead` health, keyed by transcript — what
the status line reads), and **`canary-handoff/`** (the recovery bundle).

Because `SessionStart` fires on startup / resume / clear / **compact**, the
instruction is re-injected after a compaction — so it survives context loss
without having to live in your `CLAUDE.md`.

### The token is per-user — by design

Each install generates its own token, stored at `~/.claude/canary-token` and
**never committed**. If everyone shared one hardcoded value, a prompt-injection
payload could just echo the known token and defeat the injection-detection case.

## Design decision: it does **not** block or auto-retry

A broken canary is a signal to **halt and inspect**, never to auto-retry.
Auto-retrying is the one reaction that actively helps an attacker: if injection
stripped the token, silently regenerating just hands the malicious context
another attempt.

On a Claude Code `Stop` hook, `exit 2` (or `{"decision":"block"}`) does **not**
pause for a human — it re-invokes the model, which may simply regenerate the
token and mask the problem. So instead this plugin emits a **non-blocking
`systemMessage`** (a visible ⚠️ alert with triage steps) and exits `0`. You get
the alarm; the session does not loop. It also guards on `stop_hook_active` and
**fails open** on any infrastructure problem, so a broken check never wedges a
session.

## Install

```
/plugin marketplace add thebiltheory/canary-guard
/plugin install canary-guard@thebiltheory
```

Then start a new session (or run `/hooks` once to reload). The first session
mints your token and the model begins appending it.

## Animated status line (optional) — watch the canary live or die

The repo ships `statusline/canary-cage.sh`, a tiny status-line animation that makes
the canary's health visible at a glance — and it is **honest about whether it's
actually measuring**:

- **Guarding + OK** → a yellow canary hops and sings ♪ in its cage.
- **Guarding + broken** → a red, fallen canary `x_x` with a flashing ⚠ alarm.
- **Idle** → a dim, perched canary marked `idle` — shown whenever the plugin
  is **not** validating this session, so it never fakes a healthy verdict.

It reflects *real, per-session* state. Each session's health (`ok`/`dead`) is
recorded under `$CLAUDE_CONFIG_DIR/canary-sessions/`, keyed by that session's
transcript — so concurrent sessions never fight over a single global flag, and an
idle session keeps its own verdict instead of being stolen into `idle` when
another session acts. The status line reads the file for *its own* transcript; no
file yet → `idle`. (If a Claude Code build doesn't pass a transcript path to the
status line, it falls back to the global `canary-state`.) Honors reduced motion
via `$PREFERS_REDUCED_MOTION` (freezes the loop).

Enable it (copy the bundled script to a stable path, then point the status line at it):

```bash
mkdir -p ~/.claude/scripts
cp ~/.claude/plugins/cache/thebiltheory/canary-guard/*/statusline/canary-cage.sh ~/.claude/scripts/
chmod +x ~/.claude/scripts/canary-cage.sh
```

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/scripts/canary-cage.sh",
    "refreshInterval": 1
  }
}
```

> The status line is the only Claude Code surface that can animate, and only at
> ~1 fps (`refreshInterval` minimum is 1 second) — so this is a slow, deliberate
> "hop," not smooth motion. You can't animate inside the assistant's message area.

## When the canary goes missing

| Failure | Looks like | Fix |
|---|---|---|
| **Truncation** | Token gone; response trails off or forgot something set up earlier. | `/compact` or `/clear`; reload your invariants. Trim the session if frequent. |
| **Injection** | Token gone; the model did something you didn't ask — ran a command, fetched a URL — often right after reading untrusted content. | **Stop.** Don't approve pending tool calls. Trace what entered context right before the break, quarantine the source, review everything the turn touched. |
| **Drift** | Token gone; response otherwise fine and on-task. | Re-issue or regenerate. Tighten wording if it recurs. |

## Continuity: a clean handoff to the next session

A broken canary should make you **start fresh, not silently continue** the
degraded session — auto-replaying a possibly-injected context just hands the
payload another attempt. But starting fresh shouldn't cost you your work. So on a
break, canary-guard writes a handoff to `$CLAUDE_CONFIG_DIR/canary-handoff/`:

- `transcript.jsonl` — the **complete** prior transcript, preserved verbatim
  (100% fidelity, even if Claude Code later cleans up the original).
- `handoff.md` — the original prompt, the most recent request, the last
  (possibly degraded) output, a pointer to the transcript, and a review warning.
- `PENDING` — a one-shot flag tagged with the project directory.

The **next session you start in the same project** automatically receives the
handoff via SessionStart `additionalContext`, then the flag is consumed. The new
session knows the original goal and can read the preserved transcript to recover
any detail — continuity of *intent and context*, without auto-replaying the
*corruption*. You can also resume the exact original session at any time with
`claude --resume <session_id>` (shown in the handoff).

It stays human-gated on purpose: **you** decide when to open the recovery
session, and the handoff leads with a reminder that if this was injection, the
transcript may carry a payload — review before trusting it.

## False positives — what *won't* and *will* trip it

- **Turns that end on a tool call don't alarm.** The `Stop` check skips any final
  assistant message that contains a tool call (and any message with no text) — so
  multi-step, subagent, and background-agent workflows (where a turn often ends by
  launching a tool or agent) won't false-alarm. The token is only expected on a
  genuine final prose reply.
- It **will** warn on any turn where the model legitimately doesn't echo the
  token — e.g. the first responses before it has adopted the instruction, or a
  one-off where it simply forgets (drift). Treat early warnings as expected noise,
  not an incident. Remember the asymmetry: absence is a *prompt to look*, not proof
  of compromise.

## Prior art & how this differs

The underlying technique — *instruct the model to append a token to every
response and treat its absence as evidence of override* — is **established prior
art**, not invented here:

- **Thinkst Canarytokens** — <https://canarytokens.org> — origin of the
  "canary token" term (network/file tripwires).
- **OWASP LLM Top 10** — canary tokens proposed as a prompt-injection mitigation.
- **Rebuff** (Protect AI) — <https://github.com/protectai/rebuff> — injects canary
  tokens to detect prompt-injection / system-prompt *leakage*.

What's new here is the **packaging and framing**: a Claude Code `SessionStart` →
`Stop` hook pair aimed at **output integrity** (did the response actually finish
and stay on-rails?) rather than secret exfiltration or input filtering. It's
deliberately distinct from the other Claude Code plugins that happen to use the
word "canary" — those focus on **PII/secret logging or input-side blocking**
(e.g. `canary@sonomos`, `sensitive-canary`), which is a different job.

## Verifying it works

Two switches let you confirm canary-guard is actually firing in a real session —
not just passing unit tests. Both are sentinel files under `$CLAUDE_CONFIG_DIR`
(`~/.claude`); delete the file to turn the mode off.

**See every hook fire — debug log:**

```bash
touch ~/.claude/canary-debug
```

Each hook then appends a timestamped line to `~/.claude/canary-debug.log` —
`SessionStart` on start/resume, `UserPromptSubmit` every turn, and `Stop` with its
verdict (`OK` / `DEAD` / skipped). Use Claude normally, then read the log to prove
the wiring works end-to-end. `rm ~/.claude/canary-debug` to stop.

**Force a real break — test-drift switch:**

```bash
touch ~/.claude/canary-test-drift   # then start a NEW session
```

In test-drift mode `SessionStart` mints the token and stamps state as usual but
**does not inject the rule**, so the model genuinely never emits the token. The
first reply trips a real `Stop` break → red bird → ⚠ → handoff. It's an authentic
end-to-end test triggered from *outside* the conversation (no asking the model to
misbehave). `rm ~/.claude/canary-test-drift` and restart to restore.

Full check: enable both, restart, confirm the log shows all three hooks, watch the
canary go red, then start a fresh session in the same project and confirm the
handoff is injected.

## Requirements

- `bash` and `jq` (the hooks no-op gracefully without `jq`).
- A UUID source: `uuidgen`, `/proc/sys/kernel/random/uuid`, or `openssl`
  (with a weaker fallback if none are present).
- Tested against Claude Code's hook schema as of mid-2026
  (`transcript_path`, `.message.role`, `.message.content[].text`,
  `stop_hook_active`). Hook/transcript shapes have changed across releases —
  if the check stops firing, re-verify those field names.
- Windows users need Git Bash (the scripts use a couple of bashisms).

## Uninstall

```
/plugin uninstall canary-guard@thebiltheory
```

Then delete `~/.claude/canary-token` if you want to discard the token.

## License

MIT © Bil Benhamou · made with 🐤 for Claude Code

```text
   ♪
  <o )___   keep him singing.
   \ <_  )
    `----'
```
