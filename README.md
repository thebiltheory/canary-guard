# canary-guard

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

| Hook | Script | What it does |
|---|---|---|
| `SessionStart` | `scripts/ensure-canary.sh` | On first run, mints a fresh per-user/per-machine UUID token into `$CLAUDE_CONFIG_DIR/canary-token`. Every run, injects the "append this token to every response" instruction via `additionalContext`. |
| `Stop` | `scripts/check-canary.sh` | Reads the last assistant message and checks for the token. If missing, emits a non-blocking warning. |

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

## When the canary goes missing

| Failure | Looks like | Fix |
|---|---|---|
| **Truncation** | Token gone; response trails off or forgot something set up earlier. | `/compact` or `/clear`; reload your invariants. Trim the session if frequent. |
| **Injection** | Token gone; the model did something you didn't ask — ran a command, fetched a URL — often right after reading untrusted content. | **Stop.** Don't approve pending tool calls. Trace what entered context right before the break, quarantine the source, review everything the turn touched. |
| **Drift** | Token gone; response otherwise fine and on-task. | Re-issue or regenerate. Tighten wording if it recurs. |

## False positives — what *won't* and *will* trip it

- **Tool-only / silent stops don't fire the `Stop` hook**, and the checker also
  stays silent when the last assistant message has no text — so a turn that ends
  on a tool call won't false-alarm.
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

MIT © Bil Benhamou
