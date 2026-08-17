#!/usr/bin/env bash
# UserPromptSubmit — optional per-project memory (.ai-memory/, see the
# llm-memory repo for the reference layout). Routes this prompt to the
# best-matching diagram via .ai-memory/manifest.json and injects it as
# context, wrapped in a ```mermaid block — Claude reads Mermaid natively.
#
# Silently a no-op (no output, exit 0) in any repo without
# .ai-memory/manifest.json. Always fail-open.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

root=$(ai_memory_root)
[ -f "$root/.ai-memory/manifest.json" ] || exit 0

prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)

file=$(ai_memory_match_route "$prompt")
[ -n "$file" ] && [ -f "$root/.ai-memory/$file" ] || exit 0

diagram=$(cat "$root/.ai-memory/$file" 2>/dev/null)
[ -n "$diagram" ] || exit 0

printf '<relevant_system_map path=".ai-memory/%s">\n```mermaid\n%s\n```\n</relevant_system_map>' "$file" "$diagram"
exit 0
