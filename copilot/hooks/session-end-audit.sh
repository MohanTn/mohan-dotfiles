#!/usr/bin/env bash
# sessionEnd — audit log generation (reuses Claude's session-audit.py)
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

transcript=$(printf '%s' "$input" | jq -r '.transcriptPath // empty' 2>/dev/null)

audit_dir="$HOME/.claude/audits"
mkdir -p "$audit_dir" 2>/dev/null || exit 0

stamp=$(date +%Y%m%d-%H%M%S)
out="$audit_dir/${stamp}-${session_id}.md"

if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  claude_transcript_file=$(claude_transcript "$transcript")
  if [ -n "$claude_transcript_file" ]; then
    trap 'rm -f "$claude_transcript_file"' EXIT
    python3 "$CLAUDE_HOOKS_HOME/session-end/session-audit.py" "$claude_transcript_file" --out "$out" 2>/dev/null
  fi
else
  python3 "$CLAUDE_HOOKS_HOME/session-end/session-audit.py" --cwd "$cwd" --out "$out" 2>/dev/null
fi

if [ -f "$out" ]; then
  cp -f "$out" "$audit_dir/latest.md" 2>/dev/null
  log "session-audit: wrote $out"
  ls -1t "$audit_dir"/*-*.md 2>/dev/null | tail -n +31 | xargs -r rm -f 2>/dev/null
fi

exit 0
