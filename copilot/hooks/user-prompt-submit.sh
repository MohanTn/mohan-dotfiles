#!/usr/bin/env bash
# userPromptSubmitted — state reset only. (Copilot does consume this event's
# additionalContext/modifiedPrompt; the context injection is a separate hook,
# user-prompt-submit-context.sh. This one deliberately prints nothing.) Clears
# the same per-turn state the Claude UserPromptSubmit hook performs: the
# loop-breaker counters.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

rm -f "$state_dir/loop_last_sig" "$state_dir/loop_count" 2>/dev/null
exit 0
