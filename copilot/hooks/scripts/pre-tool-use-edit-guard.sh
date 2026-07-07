#!/usr/bin/env bash
# preToolUse: edit|create — no-op guard, ported from
# claude/hooks/pre-tool-use-edit-guard.sh. Denies via a JSON
# permissionDecision on stdout (exit 0), per the Copilot hook contract.
input=$(cat)
export HOOK_INPUT="$input"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

file=$(tool_arg '.path // .file_path // .filePath')

# no-op edit guard
old=$(tool_arg '.old_str // .oldStr // .old_string')
new=$(tool_arg '.new_str // .newStr // .new_string')
if [ -n "$old" ] && [ "$old" = "$new" ]; then
  log "edit-guard: denied no-op edit on $file"
  deny_tool "The old and new strings are identical: this edit is a no-op."
  exit 0
fi

# no-op write guard for full-file creation over an existing identical file
if [ "$tool_name" = "create" ] || [ "$tool_name" = "write" ]; then
  content=$(tool_arg '.file_text // .fileText // .content')
  if [ -n "$content" ] && [ -f "$file" ]; then
    existing=$(cat "$file" 2>/dev/null)
    if [ "$content" = "$existing" ]; then
      log "edit-guard: denied no-op write on $file"
      deny_tool "The content is identical to the file's current content: this write is a no-op."
      exit 0
    fi
  fi
fi

exit 0
