#!/usr/bin/env bash
# SessionStart: map the repo to an aicode-mcp template.
#
# Runs `aicode-mcp init --quiet` in the session cwd. init keeps any template a
# project.json or .toolkit/settings.yaml already names, otherwise it writes the
# default sourceTemplate and copies the bundled templates/ into the repo. It
# never overwrites existing files, so this is safe to run on every session.
#
# Prints one user-facing line only when init created or copied something.
# Silent when aicode-mcp is not installed (enableAicodeMcp is optional).
#
# Usage: aicode-init.sh [--claude]
#   --claude  wrap the line as Claude Code SessionStart JSON: systemMessage so
#             the user sees it, additionalContext so the agent knows too.
#
# Always exits 0.
input=$(cat)

as_claude=0
for arg in "$@"; do
  [ "$arg" = "--claude" ] && as_claude=1
done

command -v aicode-mcp >/dev/null 2>&1 || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"
[ -d "$cwd" ] || exit 0

result=$(cd "$cwd" && timeout 8 aicode-mcp init --quiet 2>/dev/null)
case "$result" in
  *Created* | *Copied*) ;;
  *) exit 0 ;;
esac

message="aicode-mcp: initialised $(basename "$cwd") ($(printf '%s' "$result" | tr '\n' ';' | sed 's/;$//; s/;/, /g'))."

if [ "$as_claude" = "1" ]; then
  jq -n --arg m "$message" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
else
  printf '%s\n' "$message"
fi
exit 0
