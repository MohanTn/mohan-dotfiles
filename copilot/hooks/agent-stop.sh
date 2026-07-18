#!/usr/bin/env bash
# agentStop — adapter for the canonical goal-check gate that lives in
# claude/hooks. Translates Copilot's events.jsonl transcript into Claude's
# JSONL shape (claude_transcript, in lib/common.sh), then runs the real
# pre-tool-use-goal-capture.sh (Copilot never fires a PreToolUse hook with a
# transcript, so capture has to happen here instead) followed by the real
# stop-goal-check.sh, both unmodified.
#
# Advisory-only, by design: stop-goal-check.sh never blocks (see its own
# header comment — forcing a retry costs a whole extra AI turn for two
# lines of text). Copilot must not reimplement its own stricter policy on
# top of that; this hook always allows and only logs.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

allow() { printf '{}'; exit 0; }

transcript=$(printf '%s' "$input" | jq -r '.transcriptPath // empty' 2>/dev/null)
if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
  allow
fi

claude_transcript_file=$(claude_transcript "$transcript")
[ -n "$claude_transcript_file" ] || allow
trap 'rm -f "$claude_transcript_file"' EXIT

payload=$(jq -n --arg sid "$session_id" --arg cwd "$cwd" --arg t "$claude_transcript_file" \
  '{session_id: $sid, cwd: $cwd, transcript_path: $t}')

printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/pre-tool-use-goal-capture.sh" >/dev/null 2>&1
printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/stop-goal-check.sh" >/dev/null 2>&1

allow
