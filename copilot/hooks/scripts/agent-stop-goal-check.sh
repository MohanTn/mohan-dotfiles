#!/usr/bin/env bash
# agentStop — pre-stop goal-achievement gate, ported from
# claude/hooks/stop-goal-check.sh. Copilot's preToolUse payload carries no
# transcript path, so there is no separate goal-capture hook: this gate scans
# the transcript at stop time. Safety-critical ordering: the at-most-once
# marker check MUST come before any transcript work, so a broken
# transcriptPath can never cause an endless block loop. The marker is cleared
# by user-prompt-submit.sh on the next user prompt.
input=$(cat)
export HOOK_INPUT="$input"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

marker="$state_dir/stop_gate_fired"
[ -f "$marker" ] && exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcriptPath // empty' 2>/dev/null)
if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
  exit 0
fi

# Plain-text scan, not JSON parsing: the transcript file format is not part
# of Copilot's documented hook contract. "GOAL_CHECK:" never matches the
# "GOAL:" pattern (an underscore follows GOAL), so line numbers order the
# two reliably. The sessionStart injection lists GOAL: before GOAL_CHECK:,
# so an untouched session passes; only a stated GOAL: without a later
# GOAL_CHECK: blocks. A single-line transcript degrades to fail-open.
last_goal=$(grep -n 'GOAL:' "$transcript" 2>/dev/null | tail -1 | cut -d: -f1)
[ -z "$last_goal" ] && exit 0
last_check=$(grep -n 'GOAL_CHECK:' "$transcript" 2>/dev/null | tail -1 | cut -d: -f1)

if [ -z "$last_check" ] || [ "$last_check" -lt "$last_goal" ]; then
  touch "$marker" 2>/dev/null
  log "stop-gate: blocked, GOAL: stated without a later GOAL_CHECK:"
  jq -n '{decision: "block", reason: "A GOAL: was stated this turn but never verified. State GOAL_CHECK: ACHIEVED or GOAL_CHECK: NOT_ACHIEVED with what is missing, and address any gap before stopping."}'
fi
exit 0
