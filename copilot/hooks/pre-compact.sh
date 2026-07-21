#!/usr/bin/env bash
# preCompact — carry-forward capture, reusing the Claude pre-compact.sh.
#
# Copilot fires preCompact but discards whatever the hook prints (the CLI calls
# it through its generic `event()` path and drops the result), so unlike Claude
# Code the block cannot be injected at compaction time. userPromptSubmitted
# *does* consume additionalContext, so the block is stashed here and flushed by
# user-prompt-submit-context.sh on the next prompt — the same deferral the Pi
# port makes for the same reason (see pi/agent/extensions/hooks/index.ts).
#
# The preCompact payload carries transcriptPath/trigger/customInstructions but
# no cwd, so the working directory falls back to $PWD — the hook runs in the
# session's cwd, which is what pre-compact.sh wants for its git diffstat.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

[ -z "$cwd" ] && cwd="$PWD"

trigger=$(printf '%s' "$input" | jq -r '.trigger // "auto"' 2>/dev/null)
payload=$(jq -n --arg sid "$session_id" --arg cwd "$cwd" --arg trigger "$trigger" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PreCompact", trigger: $trigger}')

block=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/pre-compact.sh" 2>/dev/null)
if [ -n "$block" ]; then
  printf '%s' "$block" > "$state_dir/carry_forward" 2>/dev/null
  log "pre-compact: stashed carry-forward for the next prompt"
fi

printf '{}'
exit 0
