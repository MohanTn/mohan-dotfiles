#!/usr/bin/env bash
# PreToolUse (*) — invoke-time guardrail. boilerplate-guard.sh and
# bash-write-guard.sh gate HOW code files get written (bake time); this gates
# WHAT gets executed or written regardless of tool (invoke time), enforcing
# AGENTS.md's "secrets never enter this repo" rule at the moment a secret
# would actually flow through a tool call rather than only at review time.
# Reused as-is by the Copilot and Pi hook adapters, like bash-write-guard.sh.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

payload=$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null)
[ -n "$payload" ] && [ "$payload" != "null" ] || exit 0

# Tight, low-false-positive shapes for live credentials. Each pattern's
# required literal run is broken up by a regex metachar in this very file, so
# the pattern source never matches itself when this file is the tool input
# (e.g. being written or edited).
patterns=(
  'AKIA[0-9A-Z]{16}'
  '\-\-\-\-\-BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY\-\-\-\-\-'
  'gh[pousr]_[A-Za-z0-9]{36,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk-[A-Za-z0-9]{20,}'
)

for p in "${patterns[@]}"; do
  if printf '%s' "$payload" | grep -qE "$p"; then
    log "secret-guard: blocked tool call ($tool_name) matching secret pattern"
    cat >&2 <<'MSG'
Blocked: this tool call's input looks like a live secret or credential.
AGENTS.md: secrets never enter this repo. Move it to ~/.zshrc.local (or an
untracked .env) and reference it by environment variable instead.
MSG
    exit 2
  fi
done
exit 0
