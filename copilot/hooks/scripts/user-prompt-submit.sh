#!/usr/bin/env bash
# userPromptSubmitted — per-prompt state reset. Copilot does not process this
# hook's output (unlike Claude Code's UserPromptSubmit), so the GOAL reminder
# lives in session-start.sh's additionalContext; this hook only clears the
# previous turn's loop-breaker and stop-gate state so each user prompt starts
# with a clean slate.
input=$(cat)
export HOOK_INPUT="$input"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

rm -f "$state_dir/loop_last_sig" "$state_dir/loop_count" "$state_dir/stop_gate_fired" 2>/dev/null
exit 0
