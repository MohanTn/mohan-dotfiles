#!/usr/bin/env bash
# test-hook.sh — manually invoke a Copilot CLI hook the same way Copilot does:
# a JSON payload piped on stdin, a JSON decision expected on stdout.
#
# Usage:
#   test-hook.sh run <hook.sh> <payload.json|->   run one hook
#   test-hook.sh selftest                          run the regression checks
#
# The Copilot hooks reuse the Claude scripts, so ~/.claude/hooks must be
# deployed (it always is on a managed machine; the flake check copies both).
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks"

run_hook() {  # <hook.sh> <payload> -> stdout; exit = hook's exit code
  local hook="$1" payload="$2"
  printf '%s' "$payload" | bash "$HOOKS_DIR/$hook"
}

cmd_run() {
  local hook="${1:-}" payload_arg="${2:-}" payload
  [ -z "$hook" ] && { echo "usage: $0 run <hook.sh> <payload.json|->" >&2; return 2; }
  if [ "$payload_arg" = "-" ]; then payload=$(cat); else payload=$(cat "$payload_arg"); fi
  run_hook "$hook" "$payload"
}

pass_count=0
fail_count=0

# expect_out <desc> <hook> <payload> <jq-assertion over stdout JSON>
expect_out() {
  local desc="$1" hook="$2" payload="$3" assertion="$4" out
  out=$(run_hook "$hook" "$payload" 2>/dev/null)
  if printf '%s' "$out" | jq -e "$assertion" >/dev/null 2>&1; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (stdout: $out)"
    fail_count=$((fail_count + 1))
  fi
}

# Copilot delivers toolArgs as a JSON-encoded string; build payloads the same way.
payload_tool() {  # <sessionId> <toolName> <toolArgs-json>
  jq -n --arg sid "$1" --arg tn "$2" --arg ta "$3" \
    '{sessionId:$sid, timestamp:0, cwd:"/tmp", toolName:$tn, toolArgs:$ta}'
}

cmd_selftest() {
  local sid="copilot-selftest"
  rm -rf "${STATE_HOME:?}/$sid"

  expect_out "pre-tool-use denies a no-op edit" pre-tool-use.sh \
    "$(payload_tool $sid edit '{"path":"/tmp/x.txt","old_str":"a","new_str":"a"}')" \
    '.permissionDecision == "deny" and (.permissionDecisionReason | length > 0)'

  expect_out "pre-tool-use allows a real edit" pre-tool-use.sh \
    "$(payload_tool $sid edit '{"path":"/tmp/x.txt","old_str":"a","new_str":"b"}')" \
    '. == {}'

  local loop_payload
  loop_payload=$(payload_tool "$sid-loop" bash '{"command":"echo hi"}')
  run_hook pre-tool-use.sh "$loop_payload" >/dev/null 2>&1
  run_hook pre-tool-use.sh "$loop_payload" >/dev/null 2>&1
  expect_out "pre-tool-use denies the 3rd identical call" pre-tool-use.sh \
    "$loop_payload" '.permissionDecision == "deny"'
  rm -rf "${STATE_HOME:?}/$sid-loop"

  expect_out "post-tool-use ignores non-file tools" post-tool-use.sh \
    "$(payload_tool $sid bash '{"command":"echo hi"}')" '. == {}'

  expect_out "post-tool-use passes a non-code edit through the edit gate" post-tool-use.sh \
    "$(payload_tool $sid edit '{"path":"/tmp/does-not-exist-'"$sid"'/notes.md","old_str":"a","new_str":"b"}')" '. == {}'

  expect_out "agent-stop allows with no transcript" agent-stop.sh \
    "$(jq -n --arg sid "$sid" '{sessionId:$sid, cwd:"/tmp", transcriptPath:"/nonexistent", stopReason:"end_turn"}')" \
    '. == {}'

  # Copilot events.jsonl transcript: GOAL stated, no GOAL_CHECK. Advisory-only
  # (matches stop-goal-check.sh's canonical policy) — always allows, never
  # blocks, whether or not GOAL_CHECK ever shows up.
  local transcript stop_payload
  transcript=$(mktemp)
  jq -nc '{type:"user.message", data:{content:"do the thing"}}' > "$transcript"
  jq -nc '{type:"assistant.message", data:{content:"GOAL: prove the gate works\nworking on it"}}' >> "$transcript"
  stop_payload=$(jq -n --arg sid "$sid" --arg t "$transcript" \
    '{sessionId:$sid, cwd:"/tmp", transcriptPath:$t, stopReason:"end_turn"}')

  expect_out "agent-stop allows a GOAL without GOAL_CHECK (advisory only)" agent-stop.sh \
    "$stop_payload" '. == {}'
  expect_out "agent-stop still allows on a second look at the same goal" agent-stop.sh \
    "$stop_payload" '. == {}'

  jq -nc '{type:"assistant.message", data:{content:"GOAL_CHECK: ACHIEVED"}}' >> "$transcript"
  expect_out "agent-stop allows when GOAL_CHECK is stated" agent-stop.sh \
    "$stop_payload" '. == {}'
  rm -f "$transcript"

  expect_out "session-start emits the boilerplate-generator hint" session-start.sh \
    "$(jq -n --arg sid "$sid" '{sessionId:$sid, cwd:"/tmp", source:"startup"}')" \
    '.additionalContext | contains("scaffold.js")'

  # user-prompt-submit is notification-only: assert empty output + exit 0 directly
  local ups_out ups_rc
  ups_out=$(run_hook user-prompt-submit.sh "$(jq -n --arg sid "$sid" '{sessionId:$sid, cwd:"/tmp", prompt:"hello"}')")
  ups_rc=$?
  if [ "$ups_rc" -eq 0 ] && [ -z "$ups_out" ]; then
    echo "PASS: user-prompt-submit exits 0 with no output"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: user-prompt-submit (exit $ups_rc, out: $ups_out)"
    fail_count=$((fail_count + 1))
  fi

  rm -rf "${STATE_HOME:?}/$sid"

  echo "---"
  echo "$pass_count passed, $fail_count failed"
  [ "$fail_count" -eq 0 ]
}

case "${1:-}" in
  run) shift; cmd_run "$@"; exit $? ;;
  selftest) cmd_selftest; exit $? ;;
  *) echo "usage: $0 {run <hook.sh> <payload.json|->|selftest}" >&2; exit 2 ;;
esac
