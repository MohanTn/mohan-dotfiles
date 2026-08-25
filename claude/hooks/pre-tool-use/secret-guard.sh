#!/usr/bin/env bash
# PreToolUse (*) — invoke-time guardrail. pre-tool-use-edit-guard.sh gates HOW
# code files get written (bake time); this gates WHAT gets executed or
# written regardless of tool (invoke time), enforcing AGENTS.md's "secrets
# never enter this repo" rule at the moment a secret would actually flow
# through a tool call rather than only at review time.
# Reused as-is by the Copilot and Pi hook adapters, like bash-write-guard.sh.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

payload=$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null)
[ -n "$payload" ] && [ "$payload" != "null" ] || exit 0

# LEAK_VALUE_PATTERNS and LEAK_ENV_READ_PATTERNS: lib/common.sh, shared
# with secret-post-guard.sh so the two layers never drift apart.
for p in "${LEAK_VALUE_PATTERNS[@]}" "${LEAK_ENV_READ_PATTERNS[@]}"; do
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
