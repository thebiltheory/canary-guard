#!/usr/bin/env bash
# UserPromptSubmit hook — reinforcement.
#
# Re-injects the output-integrity RULE into context on every user turn, so the
# instruction stays "recent" and compliance doesn't decay as the session grows.
# (Emitting a token at the start of a reply only repeats a nonce; re-reading the
# rule is what actually reinforces it.) No-op without a token. Fail-open.

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TOKEN_FILE="$CONFIG_DIR/canary-token"

[ -s "$TOKEN_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
token=$(head -n1 "$TOKEN_FILE" 2>/dev/null)
[ -n "$token" ] || exit 0

ctx="Output-integrity reminder: begin AND end your reply with this exact token, each on its own line, verbatim and unmodified — $token"

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
