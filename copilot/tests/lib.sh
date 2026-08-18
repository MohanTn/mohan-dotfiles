#!/usr/bin/env bash
# Shared harness for the Copilot hook tests. Sourced by every *.test.sh in
# this folder; not a test itself.
#
# Copilot's contract: a JSON payload on stdin, a JSON decision on stdout.
# The hooks themselves reuse the Claude scripts through payload translation,
# so ~/.claude/hooks must be deployed for any of this to pass (it always is
# on a managed machine; the flake check copies both trees).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The hooks live beside this folder, not in it — that separation is the point.
# COPILOT_HOOKS_DIR overrides it (the flake check runs against $HOME copies).
HOOKS_DIR="${COPILOT_HOOKS_DIR:-$(dirname "$TESTS_DIR")/hooks}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks"

pass_count=0
fail_count=0

run_hook() {  # <hook.sh> <payload> -> stdout; exit = hook's exit code
  local hook="$1" payload="$2"
  printf '%s' "$payload" | bash "$HOOKS_DIR/$hook"
}

ok() {   echo "PASS: $1"; pass_count=$((pass_count + 1)); }
bad() {  echo "FAIL: $1"; fail_count=$((fail_count + 1)); }

# expect_out <desc> <hook> <payload> <jq-assertion over stdout JSON>
expect_out() {
  local desc="$1" hook="$2" payload="$3" assertion="$4" out
  out=$(run_hook "$hook" "$payload" 2>/dev/null)
  if printf '%s' "$out" | jq -e "$assertion" >/dev/null 2>&1; then
    ok "$desc"
  else
    bad "$desc (stdout: $out)"
  fi
}

# expect_silent <desc> <hook> <payload> — exit 0 and nothing on stdout. A jq
# assertion cannot express this: there is no JSON to assert against.
expect_silent() {
  local desc="$1" hook="$2" payload="$3" out rc
  out=$(run_hook "$hook" "$payload" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "$desc"; else bad "$desc (exit $rc, out: $out)"; fi
}

# refute_contains <desc> <actual> <needle>
refute_contains() {
  local desc="$1" actual="$2" needle="$3"
  if printf '%s' "$actual" | grep -qF "$needle"; then bad "$desc"; else ok "$desc"; fi
}

# Copilot delivers toolArgs as a JSON-encoded string; build payloads the same way.
payload_tool() {  # <sessionId> <toolName> <toolArgs-json>
  jq -n --arg sid "$1" --arg tn "$2" --arg ta "$3" \
    '{sessionId:$sid, timestamp:0, cwd:"/tmp", toolName:$tn, toolArgs:$ta}'
}

# Every *.test.sh ends with this: prints the tally, sets the exit code.
summary() {
  echo "---"
  echo "$pass_count passed, $fail_count failed"
  [ "$fail_count" -eq 0 ]
}
