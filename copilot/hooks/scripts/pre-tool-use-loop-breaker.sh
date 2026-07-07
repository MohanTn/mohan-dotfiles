#!/usr/bin/env bash
# preToolUse: all tools — tool-call loop breaker (consecutive-only, not
# cumulative), ported from claude/hooks/pre-tool-use-loop-breaker.sh. Denies
# via a JSON permissionDecision on stdout (exit 0).
input=$(cat)
export HOOK_INPUT="$input"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

[ -z "$tool_name" ] && exit 0
sig=$(printf '%s' "$input" | jq -c '{toolName, toolArgs}' 2>/dev/null | md5sum | cut -d' ' -f1)
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
  log "loop-breaker: denied after $count consecutive identical calls"
  deny_tool "This exact tool call has been attempted ${count} times in a row with nothing different in between. Stop and explain what's failing instead of retrying the same call again."
  exit 0
fi

exit 0
