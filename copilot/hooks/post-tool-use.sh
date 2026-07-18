#!/usr/bin/env bash
# postToolUse — import/type-check/build gate + lint/build/test run after file
# edits, reusing the Claude Code post-tool-use-edit.sh and
# post-tool-use-validate-and-test.sh unmodified. Copilot's postToolUse cannot
# block a write that already happened (neither can Claude's), but it can
# append additionalContext to the tool result — the gates' findings arrive
# there. Non-zero exits are logged and skipped (fail-open), so always exit 0.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

case "$tool_name" in
  create | edit | str_replace_editor | apply_patch) ;;
  *) printf '{}'; exit 0 ;;
esac

payload=$(claude_payload)
[ -z "$payload" ] && { printf '{}'; exit 0; }

err=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/post-tool-use-edit.sh" 2>&1 >/dev/null)
if [ $? -eq 2 ] && [ -n "$err" ]; then
  printf '%s' "$err" | jq -Rs '{additionalContext: ("Post-edit gate FAILED — fix this before proceeding:\n" + .)}'
  exit 0
fi

test_err=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/post-tool-use-validate-and-test.sh" 2>&1 >/dev/null)
if [ $? -ne 0 ] && [ -n "$test_err" ]; then
  printf '%s' "$test_err" | jq -Rs '{additionalContext: .}'
  exit 0
fi

printf '{}'
exit 0
