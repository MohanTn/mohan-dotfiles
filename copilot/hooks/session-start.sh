#!/usr/bin/env bash
# sessionStart — project digest (reuses the Claude hook) + the boilerplate-generator
# hint. The digest is the only path by which a project's own CLAUDE.md reaches
# Copilot, which loads just the global copilot-instructions.md. The GOAL/GOAL_CHECK
# instruction now lives in agents/AGENTS.md, which that file is generated from.
# On Claude Code the boilerplate hint fires per turn only when a prompt looks
# boilerplate-flavored (claude/hooks/boilerplate-hint.sh); here it is appended
# unconditionally, once per session. Copilot does consume userPromptSubmitted's
# additionalContext (see user-prompt-submit-context.sh), so the keyword-gated
# hook could be ported across as well — that would trade this one-off cost for a
# per-turn one, and hasn't been measured either way.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

payload=$(jq -n --arg sid "$session_id" --arg cwd "$cwd" \
  '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}')
digest=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/session-start.sh" 2>/dev/null)

hint_file="$HOME/.agents/boilerplats/AGENT-HINT.md"
if [ -f "$hint_file" ]; then
  boilerplate_hint=$(cat "$hint_file")
else
  boilerplate_hint="Boilerplate generator available at ~/.agents/boilerplats/scaffold.js (run 'home-manager switch --impure' if that path doesn't exist yet)."
fi

printf '%s\n\n%s' "$digest" "$boilerplate_hint" \
  | jq -Rs '{additionalContext: .}'
exit 0
