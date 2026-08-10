#!/usr/bin/env bash
# UserPromptSubmit — optional per-project memory (.ai-memory/, see the
# llm-memory repo for the reference layout). Two things happen here:
#
#   1. Flush any nudge remember-memory.sh stashed at the end of the previous
#      turn (Stop-hook output isn't delivered to the model, so that's the
#      earliest point it can actually reach one).
#   2. Route this prompt to the best-matching diagram via
#      .ai-memory/manifest.json and inject it as context, wrapped in a
#      ```mermaid block — Claude reads Mermaid natively.
#
# Silently a no-op (no output, exit 0) in any repo without
# .ai-memory/manifest.json. Always fail-open.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

root=$(ai_memory_root)
[ -f "$root/.ai-memory/manifest.json" ] || exit 0

prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)

out=""

# A nudge is bound to the repo it was stashed in (state_dir is per-session,
# not per-repo): flush it only when this prompt's root matches, otherwise
# leave it for a later prompt back in that repo.
nudge_file="$state_dir/memory_nudge"
if [ -f "$nudge_file" ] && [ "$(cat "$state_dir/memory_nudge_root" 2>/dev/null)" = "$root" ]; then
  out=$(cat "$nudge_file" 2>/dev/null)
  rm -f "$nudge_file" "$state_dir/memory_nudge_root" 2>/dev/null
fi

file=$(ai_memory_match_route "$prompt")
if [ -n "$file" ] && [ -f "$root/.ai-memory/$file" ]; then
  diagram=$(cat "$root/.ai-memory/$file" 2>/dev/null)
  if [ -n "$diagram" ]; then
    block=$(printf '<relevant_system_map path=".ai-memory/%s">\n```mermaid\n%s\n```\n</relevant_system_map>' "$file" "$diagram")
    if [ -n "$out" ]; then
      out=$(printf '%s\n\n%s' "$out" "$block")
    else
      out="$block"
    fi
  fi
fi

[ -n "$out" ] && printf '%s' "$out"
exit 0
