#!/usr/bin/env bash
# UserPromptSubmit — reset per-turn state.
input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)
session_id=${session_id:-default}
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks/${session_id}"
mkdir -p "$state_dir"
rm -f "$state_dir/loop_last_sig" "$state_dir/loop_count" 2>/dev/null

exit 0
