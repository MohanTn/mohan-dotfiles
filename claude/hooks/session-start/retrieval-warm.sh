#!/usr/bin/env bash
# SessionStart: make sure hybrid-retrieval has this repo indexed.
#
# Runs `hybrid-retrieval ensure`, which starts the resident daemon if needed
# and indexes an unseen repo in the background without waiting for it. Prints
# one user-facing line when indexing just started or the tool is missing, and
# nothing once the repo is ready. context-augment.py then picks the index up on
# later prompts.
#
# Usage: retrieval-warm.sh [--claude]
#   --claude  wrap the line as Claude Code SessionStart JSON: systemMessage so
#             the user sees it, additionalContext so the agent knows too.
#             Copilot and pi call it bare and render the plain line themselves.
#
# Non-optional, so a missing binary is reported rather than skipped, except in
# the docker sandbox (IS_SANDBOX=1), which never installs the tool. Always exits 0.
input=$(cat)

as_claude=0
for arg in "$@"; do
  [ "$arg" = "--claude" ] && as_claude=1
done

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"

message=""
if command -v hybrid-retrieval >/dev/null 2>&1; then
  state=$(timeout 8 hybrid-retrieval ensure "$cwd" 2>/dev/null | tail -n 1)
  if [ "$state" = "indexing" ]; then
    repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")
    message="hybrid-retrieval: indexing $(basename "$repo") in the background. Retrieval will be used starting next session."
  fi
elif [ "${IS_SANDBOX:-}" != "1" ]; then
  message="hybrid-retrieval is not installed. Run ./setup.sh in mohan-dotfiles to install it."
fi

[ -z "$message" ] && exit 0

if [ "$as_claude" = "1" ]; then
  jq -n --arg m "$message" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
else
  printf '%s\n' "$message"
fi
exit 0
