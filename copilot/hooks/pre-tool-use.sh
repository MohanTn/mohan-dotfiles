#!/usr/bin/env bash
# preToolUse — no-op edit guard, secret/credential guardrail, and
# consecutive-call loop breaker, reusing the Claude Code hook scripts via
# payload translation. Copilot treats a crash or
# non-zero exit as deny (fail-closed), so every path below ends in exit 0
# with a JSON decision on stdout: {} for the default permission flow, or an
# explicit deny carrying the reused script's stderr as the reason.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.copilot/hooks/lib/common.sh"

deny() {
  jq -n --arg r "$1" '{permissionDecision: "deny", permissionDecisionReason: $r}'
  exit 0
}

payload=$(claude_payload)
[ -z "$payload" ] && { printf '{}'; exit 0; }

# Invoke-time guardrail: applies to every tool, independent of tool_name.
err=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/secret-guard.sh" 2>&1 >/dev/null)
[ $? -eq 2 ] && deny "$err"

case "$tool_name" in
  create | edit | str_replace_editor | apply_patch)
    err=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/pre-tool-use-edit-guard.sh" 2>&1 >/dev/null)
    [ $? -eq 2 ] && deny "$err"
    # boilerplate mandate: `create` (→Write) must come from scaffold.js,
    # edit tools (→Edit) must keep the scaffold:inject marker
    err=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/boilerplate-guard.sh" 2>&1 >/dev/null)
    [ $? -eq 2 ] && deny "$err"
    ;;
  bash | shell)
    # Both guards only read tool_input.command, which claude_payload passes
    # through from toolArgs untouched. Allowlist first: a command that is not
    # allowed to run at all needs no further inspection.
    err=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/bash-allowlist-guard.sh" 2>&1 >/dev/null)
    [ $? -eq 2 ] && deny "$err"
    err=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/bash-write-guard.sh" 2>&1 >/dev/null)
    [ $? -eq 2 ] && deny "$err"
    ;;
esac

err=$(printf '%s' "$payload" | bash "$CLAUDE_HOOKS_HOME/pre-tool-use-loop-breaker.sh" 2>&1 >/dev/null)
[ $? -eq 2 ] && deny "$err"

printf '{}'
exit 0
