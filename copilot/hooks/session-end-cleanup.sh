#!/usr/bin/env bash
# sessionEnd — prune stale hook state and generate the same session audit Claude
# produces, reusing session-end-cleanup.sh and session-end-audit.sh unmodified.
# Copilot hook state lives in the same ~/.local/state/claude-hooks tree the
# Claude hooks use (see lib/common.sh).
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

bash "$HOME/.claude/hooks/session-end-cleanup.sh"

transcript=$(printf '%s' "$input" | jq -r '.transcriptPath // empty' 2>/dev/null)
claude_transcript_file=$(claude_transcript "$transcript" 2>/dev/null)
if [ -n "$claude_transcript_file" ]; then
  trap 'rm -f "$claude_transcript_file"' EXIT
  payload=$(jq -n --arg sid "$session_id" --arg cwd "$cwd" --arg t "$claude_transcript_file" \
    '{session_id: $sid, cwd: $cwd, transcript_path: $t}')
else
  payload=$(jq -n --arg sid "$session_id" --arg cwd "$cwd" '{session_id: $sid, cwd: $cwd}')
fi
printf '%s' "$payload" | bash "$HOME/.claude/hooks/session-end-audit.sh" >/dev/null 2>&1

exit 0
