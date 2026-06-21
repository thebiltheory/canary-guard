# output-canary

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
/plugin marketplace add thebiltheory/claude-output-canary
/plugin install output-canary@canary
```

Then start a new session (or run `/hooks` once to reload). The first session
mints your token and the model begins appending it.

## When the canary goes missing

| Failure | Looks like | Fix |
|---|---|---|
| **Truncation** | Token gone; response trails off or forgot something set up earlier. | `/compact` or `/clear`; reload your invariants. Trim the session if frequent. |
| **Injection** | Token gone; the model did something you didn't ask — ran a command, fetched a URL — often right after reading untrusted content. | **Stop.** Don't approve pending tool calls. Trace what entered context right before the break, quarantine the source, review everything the turn touched. |
| **Drift** | Token gone; response otherwise fine and on-task. | Re-issue or regenerate. Tighten wording if it recurs. |

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
/plugin uninstall output-canary@canary
```

Then delete `~/.claude/canary-token` if you want to discard the token.

## License

MIT © Bil Benhamou
