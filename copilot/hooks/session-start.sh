#!/usr/bin/env bash
# sessionStart — project digest (reuses the Claude hook) + the GOAL/GOAL_CHECK
# standing instruction + the boilerplate-generator hint. On Claude Code both
# are injected per turn (GOAL via UserPromptSubmit, the boilerplate hint only
# when a prompt looks boilerplate-flavored, see claude/hooks/boilerplate-hint.sh);
# Copilot fires userPromptSubmitted but ignores its output, so this once-per-session
# injection is the available equivalent for both (agent-stop.sh enforces the
# GOAL half; the hint has no per-turn re-trigger, so it runs unconditionally
# here instead of being keyword-gated).
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

printf '%s\n\n%s\n\n%s' "$digest" \
'Standing instruction for every substantial request in this session: begin your reply with "GOAL: <one-sentence objective>" and, before finishing that turn, state "GOAL_CHECK: ACHIEVED" or "GOAL_CHECK: NOT_ACHIEVED — <gap>".' \
  "$boilerplate_hint" \
  | jq -Rs '{additionalContext: .}'
exit 0
