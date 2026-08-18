#!/usr/bin/env bash
# PreToolUse: * — 2.4 tool-call loop breaker (consecutive-only, not cumulative)
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

sig=$(printf '%s' "$input" | jq -c '{tool_name, tool_input}' 2>/dev/null | md5sum | cut -d' ' -f1)
[ -z "$sig" ] && exit 0

last_sig_file="$state_dir/loop_last_sig"
count_file="$state_dir/loop_count"

last_sig=$(cat "$last_sig_file" 2>/dev/null || echo "")
if [ "$sig" = "$last_sig" ]; then
  count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
else
  count=1
fi
printf '%s' "$sig" > "$last_sig_file" 2>/dev/null
printf '%s' "$count" > "$count_file" 2>/dev/null

if [ "$count" -ge 3 ]; then
  log "loop-breaker: blocked after $count consecutive identical calls"
  echo "This exact tool call has been attempted ${count} times in a row with nothing different in between. Stop and explain what's failing instead of retrying the same call again." >&2
  exit 2
fi

exit 0
