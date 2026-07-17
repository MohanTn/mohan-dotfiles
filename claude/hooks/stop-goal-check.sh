#!/usr/bin/env bash
# Stop — advisory goal-check logger. Never blocks Stop (no exit 2): a forced
# block costs a whole extra AI turn just to emit two lines, which isn't worth
# it. This only logs whether GOAL_CHECK showed up, for visibility.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

goal_file="$state_dir/goal.txt"
[ ! -f "$goal_file" ] && exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
goal=$(cat "$goal_file" 2>/dev/null)

# Scope to assistant text after the most recent user message — same pattern as
# pre-tool-use-goal-capture.sh's scan — so a GOAL_CHECK: from an earlier turn
# can't satisfy this turn's gate.
found_check=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  last_user_line=$(jq -c 'select(.type=="user") | input_line_number' "$transcript" 2>/dev/null | tail -1)
  last_user_line="${last_user_line:-0}"
  jq -r --argjson ln "$last_user_line" \
    'select(.type=="assistant" and input_line_number > $ln) | .message.content[]? | select(.type=="text") | .text' \
    "$transcript" 2>/dev/null | grep -q "GOAL_CHECK:" && found_check=1
fi

if [ "$found_check" = "0" ]; then
  log "stop-gate: no GOAL_CHECK found for goal: $goal"
fi

rm -f "$goal_file" 2>/dev/null
exit 0
