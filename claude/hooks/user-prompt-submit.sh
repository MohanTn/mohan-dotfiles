#!/usr/bin/env bash
# UserPromptSubmit — reset per-turn state; inject the MCP document-reader hint.
# The GOAL/GOAL_CHECK instruction lives in agents/AGENTS.md, not here.
input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)
session_id=${session_id:-default}
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks/${session_id}"
mkdir -p "$state_dir"
rm -f "$state_dir/goal.txt" "$state_dir/loop_last_sig" "$state_dir/loop_count" 2>/dev/null

prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)

# Inject MCP tool instruction when supported document files are referenced
if printf '%s' "$prompt" | grep -qiE '@[^ ]+\.(pdf|docx|xlsx|xls)'; then
  echo "IMPORTANT: For any .pdf, .docx, .xlsx, or .xls files referenced in this prompt, use the mcp__files-mcp__convert_file tool to read them — do NOT use the Read tool for these file types."
fi

exit 0
