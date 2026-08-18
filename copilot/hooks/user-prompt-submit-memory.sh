#!/usr/bin/env bash
# userPromptSubmitted — .ai-memory/ injection, reusing Claude's
# inject-memory.sh unmodified (see the llm-memory repo for the reference
# .ai-memory/ layout this reads).
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)
payload=$(jq -n --arg sid "$session_id" --arg cwd "$cwd" --arg prompt "$prompt" \
  '{session_id: $sid, cwd: $cwd, prompt: $prompt}')
context=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/user-prompt-submit/inject-memory.sh" 2>/dev/null)

if [ -n "$context" ]; then
  printf '%s' "$context" | jq -Rs '{additionalContext: .}'
fi
exit 0
