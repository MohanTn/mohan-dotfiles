#!/usr/bin/env bash
# PreToolUse: Edit|Write — 2.2 no-op guard
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# 2.2 — edit no-op guard
old=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
new=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
if [ -n "$old" ] && [ "$old" = "$new" ]; then
  log "edit-guard: blocked no-op edit on $file"
  echo "old_string and new_string are identical — this edit is a no-op." >&2
  exit 2
fi

if [ "$tool_name" = "Write" ]; then
  content=$(printf '%s' "$input" | jq -r '.tool_input.content // empty' 2>/dev/null)
  if [ -n "$content" ] && [ -f "$file" ]; then
    existing=$(cat "$file" 2>/dev/null)
    if [ "$content" = "$existing" ]; then
      log "edit-guard: blocked no-op write on $file"
      echo "Write content is identical to the file's current content — this write is a no-op." >&2
      exit 2
    fi
  fi
fi

exit 0
