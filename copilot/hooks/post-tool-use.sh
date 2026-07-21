#!/usr/bin/env bash
# postToolUse — import/type-check/build gate after file edits, reusing the
# Claude Code post-tool-use-edit.sh unmodified. Copilot's postToolUse cannot
# block a write that already happened (neither can Claude's), but it can
# append additionalContext to the tool result — the gate's findings arrive
# there. Non-zero exits are logged and skipped (fail-open), so always exit 0.
# There is deliberately no lint/build/test run anywhere in the hook chain: a
# whole-project compile per edit times out on anything large, and at sessionEnd
# there is no further AI turn left to feed the findings to. Builds are the
# model's to run explicitly. (This used to point at a POST_TEST_VALIDATOR.md
# describing a session-end validator that was never implemented.)
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

printf '{}'
exit 0
