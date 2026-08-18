#!/usr/bin/env bash
# user-prompt-submit-memory.sh — reuses Claude's inject-memory.sh unmodified.
# This drives the legacy keyword-routing manifest on purpose: the Claude suite
# covers the current single-diagram schema, and both must keep working.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sid="copilot-selftest-mem"
rm -rf "${STATE_HOME:?}/$sid"

mem_repo=$(mktemp -d)
git -C "$mem_repo" init -q 2>/dev/null
mkdir -p "$mem_repo/.ai-memory/diagrams/debug"
printf '{"routes":[{"keywords":["segfault"],"file":"diagrams/debug/playbook.mmd","priority":9}]}' \
  > "$mem_repo/.ai-memory/manifest.json"
printf 'flowchart TD\n  A[Segfault] --> B[Check Docker]\n' \
  > "$mem_repo/.ai-memory/diagrams/debug/playbook.mmd"

expect_out "user-prompt-submit-memory injects the diagram a prompt routes to" \
  user-prompt-submit-memory.sh \
  "$(jq -n --arg sid "$sid" --arg cwd "$mem_repo" '{sessionId:$sid, cwd:$cwd, prompt:"debugging a segfault in prod"}')" \
  '.additionalContext | contains("Check Docker")'

rm -rf "$mem_repo" "${STATE_HOME:?}/$sid"
summary
