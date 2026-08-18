#!/usr/bin/env bash
# test-hook.sh — entry point for the Copilot hook tests, which live here rather
# than in copilot/hooks/ so the deployed ~/.copilot/hooks tree carries only
# hooks.
#
# Usage:
#   test-hook.sh run <hook.sh> <payload.json|->   run one hook by hand
#   test-hook.sh selftest                          run every *.test.sh here
#
# One area per file (pre-tool-use, post-tool-use, session, prompt-context,
# memory, pre-compact); each is also runnable on its own:
#   bash copilot/tests/pre-tool-use.test.sh
#
# The Copilot hooks reuse the Claude scripts, so ~/.claude/hooks must be
# deployed (it always is on a managed machine; the flake check copies both).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cmd_run() {
  local hook="${1:-}" payload_arg="${2:-}" payload
  [ -z "$hook" ] && { echo "usage: $0 run <hook.sh> <payload.json|->" >&2; return 2; }
  if [ "$payload_arg" = "-" ]; then payload=$(cat); else payload=$(cat "$payload_arg"); fi
  run_hook "$hook" "$payload"
}

# Each *.test.sh is its own process with its own tally; add them up here.
cmd_selftest() {
  local total_pass=0 total_fail=0 f out
  for f in "$TESTS_DIR"/*.test.sh; do
    [ -f "$f" ] || continue
    out=$(bash "$f" 2>&1)
    printf '%s\n' "$out" | grep -Ev '^(---|[0-9]+ passed)'
    total_pass=$((total_pass + $(printf '%s\n' "$out" | grep -c '^PASS: ')))
    total_fail=$((total_fail + $(printf '%s\n' "$out" | grep -c '^FAIL: ')))
  done
  echo "---"
  echo "$total_pass passed, $total_fail failed"
  [ "$total_fail" -eq 0 ]
}

case "${1:-}" in
  run) shift; cmd_run "$@"; exit $? ;;
  selftest) cmd_selftest; exit $? ;;
  *) echo "usage: $0 {run <hook.sh> <payload.json|->|selftest}" >&2; exit 2 ;;
esac
