#!/usr/bin/env bash
# userPromptSubmitted — state reset only. (Copilot does consume this event's
# additionalContext/modifiedPrompt; the context injection is a separate hook,
# user-prompt-submit-context.sh. This one deliberately prints nothing.) Clears
# the same per-turn state the Claude UserPromptSubmit
# hook performs: the loop-breaker counters and the captured goal. goal.txt has
# to go too — agent-stop.sh runs goal-capture, which no-ops when the file
# already exists, so a goal left behind by a turn that ended without a stop
# event would be carried into every later turn.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

rm -f "$state_dir/loop_last_sig" "$state_dir/loop_count" "$state_dir/goal.txt" 2>/dev/null
exit 0
