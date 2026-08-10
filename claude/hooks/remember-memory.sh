#!/usr/bin/env bash
# Stop — advisory "you might want to remember this" nudge for .ai-memory/
# (see the llm-memory repo). When this turn's captured GOAL: (see
# pre-tool-use-goal-capture.sh) routes to a tracked diagram via
# .ai-memory/manifest.json and the transcript shows GOAL_CHECK: ACHIEVED,
# stash a reminder to update that diagram.
#
# Claude Code does not deliver Stop-hook stdout to the model (only a
# {"decision":"block"} would, and forcing an extra turn for two lines of
# text isn't worth it — same policy as stop-goal-check.sh), so the nudge is
# stashed to session state and picked up by inject-memory.sh at the START of
# the next turn instead, the same carry-forward technique pre-compact.sh
# uses across compaction.
#
# Silently a no-op without .ai-memory/manifest.json. Never blocks. Always
# exits 0.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

root=$(ai_memory_root)
[ -f "$root/.ai-memory/manifest.json" ] || exit 0

goal_file="$state_dir/goal.txt"
[ -f "$goal_file" ] || exit 0
goal=$(cat "$goal_file" 2>/dev/null)
[ -n "$goal" ] || exit 0

file=$(ai_memory_match_route "$goal")
[ -n "$file" ] || exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Same scoping as stop-goal-check.sh: only assistant text after the most
# recent user message can satisfy this turn's check.
last_user_line=$(jq -c 'select(.type=="user") | input_line_number' "$transcript" 2>/dev/null | tail -1)
last_user_line="${last_user_line:-0}"
achieved=$(jq -r --argjson ln "$last_user_line" \
  'select(.type=="assistant" and input_line_number > $ln) | .message.content[]? | select(.type=="text") | .text' \
  "$transcript" 2>/dev/null | grep -c "GOAL_CHECK: ACHIEVED")

[ "${achieved:-0}" -ge 1 ] || exit 0

nudge=$(printf '<ai_memory_reminder>This turn resolved: %s\nThat maps to .ai-memory/%s. If you learned something worth keeping (a fix, a gotcha, a structural change), append a node/edge to that file now, and add any new trigger keywords to .ai-memory/manifest.json.</ai_memory_reminder>' "$goal" "$file")
printf '%s' "$nudge" > "$state_dir/memory_nudge" 2>/dev/null
log "remember-memory: stashed nudge for $file"
exit 0
