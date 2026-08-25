#!/usr/bin/env bash
# sessionStart — project digest (reuses the Claude hook). The digest is the
# only path by which a project's own CLAUDE.md reaches Copilot, which loads
# just the global copilot-instructions.md. The GOAL/GOAL_CHECK instruction now
# lives in agents/AGENTS.md, which that file is generated from.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

payload=$(jq -n --arg sid "$session_id" --arg cwd "$cwd" \
  '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}')
digest=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/session-start/session-start.sh" 2>/dev/null)

printf '%s' "$digest" \
  | jq -Rs '{additionalContext: .}'
exit 0
