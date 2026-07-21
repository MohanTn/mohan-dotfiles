#!/usr/bin/env bash
# userPromptSubmitted — context augmentation wrapper (reuses Claude's context-augment.py)
#
# The prompt MUST be forwarded: context-augment.py keys everything off it and
# returns silently on a payload without one (its MIN_WORDS guard), so omitting
# the field turns this hook into a no-op that still looks wired up. See the
# "context augmentation forwards the prompt" case in test-hook.sh selftest.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)
payload=$(jq -n --arg sid "$session_id" --arg cwd "$cwd" --arg prompt "$prompt" \
  '{session_id: $sid, cwd: $cwd, prompt: $prompt}')
context=$(printf '%s' "$payload" | python3 "$CLAUDE_HOOKS_HOME/context-augment.py" 2>/dev/null)

# Flush any carry-forward block stashed by pre-compact.sh. Copilot ignores the
# preCompact hook's own output, so this is the first point after a compaction
# at which the block can actually reach the model. Delivered once, then dropped.
carry_file="$state_dir/carry_forward"
if [ -f "$carry_file" ]; then
  carry=$(cat "$carry_file" 2>/dev/null)
  rm -f "$carry_file" 2>/dev/null
  if [ -n "$carry" ]; then
    context=$(printf '%s\n\n%s' "$carry" "$context")
  fi
fi

if [ -n "$context" ]; then
  printf '%s' "$context" | jq -Rs '{additionalContext: .}'
fi
exit 0
