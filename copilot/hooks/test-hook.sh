#!/usr/bin/env bash
# test-hook.sh — manually invoke a Copilot hook script the same way Copilot
# CLI does: a camelCase JSON payload piped on stdin, nothing else. Reports
# exit code, stdout, and stderr so a hook's behavior can be checked without
# a live session.
#
# Usage:
#   test-hook.sh list                          list hooks with their event + default payload
#   test-hook.sh run <hook.sh> [payload.json]  run a hook (default payload if omitted)
#   echo '{"...":"..."}' | test-hook.sh run <hook.sh> -   run with a custom payload on stdin
#   test-hook.sh selftest                      run the built-in regression checks
#
# Output contract, per Copilot's hook reference: hooks exit 0 and speak JSON
# on stdout. preToolUse denies with {"permissionDecision":"deny",...},
# agentStop blocks with {"decision":"block",...}, sessionStart/postToolUse
# inject {"additionalContext":"..."}. Empty stdout means allow/continue.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/copilot-hooks"
TEST_SESSION_ID="manual-test"

# hook basename -> "event_name::one-line purpose"
declare -A HOOK_INFO=(
  [session-start.sh]="sessionStart::inject project digest + GOAL convention as additionalContext"
  [user-prompt-submit.sh]="userPromptSubmitted::clear prior loop/stop-gate state"
  [pre-tool-use-edit-guard.sh]="preToolUse (edit/create)::deny no-op edits/writes"
  [pre-tool-use-loop-breaker.sh]="preToolUse (*)::deny 3rd consecutive identical tool call"
  [post-tool-use-edit.sh]="postToolUse (edit/create)::import/type-check/build gate after edits"
  [agent-stop-goal-check.sh]="agentStop::block stop until GOAL_CHECK: was stated"
  [session-end-cleanup.sh]="sessionEnd::prune stale hook state"
)

default_payload() {
  local hook="$1" cwd="$PWD"
  case "$hook" in
    session-start.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{sessionId:$sid, cwd:$cwd, source:"startup"}'
      ;;
    user-prompt-submit.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{sessionId:$sid, cwd:$cwd, prompt:"Please investigate and fix the login bug"}'
      ;;
    pre-tool-use-edit-guard.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{sessionId:$sid, cwd:$cwd, toolName:"edit",
          toolArgs:{path:"/tmp/example.txt", old_str:"same text", new_str:"same text"}}'
      ;;
    pre-tool-use-loop-breaker.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{sessionId:$sid, cwd:$cwd, toolName:"bash", toolArgs:{command:"echo hi"}}'
      ;;
    post-tool-use-edit.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{sessionId:$sid, cwd:$cwd, toolName:"edit",
          toolArgs:{path:"/tmp/example.md"},
          toolResult:{resultType:"success", textResultForLlm:"ok"}}'
      ;;
    agent-stop-goal-check.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{sessionId:$sid, cwd:$cwd, transcriptPath:"/nonexistent/transcript", stopReason:"end_turn"}'
      ;;
    session-end-cleanup.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{sessionId:$sid, cwd:$cwd}'
      ;;
    *)
      echo '{}'
      ;;
  esac
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") list
  $(basename "$0") run <hook.sh> [payload.json]
  echo '{"...":"..."}' | $(basename "$0") run <hook.sh> -
  $(basename "$0") selftest
EOF
}

cmd_list() {
  for hook in "${!HOOK_INFO[@]}"; do
    printf '%s\n' "$hook"
  done | sort | while read -r hook; do
    event="${HOOK_INFO[$hook]%%::*}"
    purpose="${HOOK_INFO[$hook]#*::}"
    printf '%-30s %-28s %s\n' "$hook" "$event" "$purpose"
  done
}

# run_hook <hook.sh> <payload-json-string>
# Fills HOOK_STDOUT / HOOK_STDERR / HOOK_EXIT globals, prints nothing.
HOOK_STDOUT=""
HOOK_STDERR=""
HOOK_EXIT=0
run_hook() {
  local hook="$1" payload="$2" hook_path
  if [[ "$hook" == */* ]]; then
    hook_path="$hook"
  else
    hook_path="$HOOKS_DIR/$hook"
  fi

  if [ ! -f "$hook_path" ]; then
    echo "No such hook script: $hook_path" >&2
    HOOK_EXIT=127
    return 127
  fi

  local stdout_file stderr_file
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  printf '%s' "$payload" | bash "$hook_path" >"$stdout_file" 2>"$stderr_file"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$stdout_file")
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"
  return "$HOOK_EXIT"
}

cmd_run() {
  local hook="${1:-}" payload_arg="${2:-}"
  if [ -z "$hook" ]; then
    usage >&2
    return 2
  fi

  local payload
  if [ "$payload_arg" = "-" ]; then
    payload=$(cat)
  elif [ -n "$payload_arg" ]; then
    if [ ! -f "$payload_arg" ]; then
      echo "No such payload file: $payload_arg" >&2
      return 2
    fi
    payload=$(cat "$payload_arg")
  else
    payload=$(default_payload "$(basename "$hook")")
  fi

  if command -v jq >/dev/null 2>&1 && ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    echo "Payload is not valid JSON:" >&2
    printf '%s\n' "$payload" >&2
    return 1
  fi

  echo "==> Running: $hook"
  echo "==> Payload:"
  printf '%s' "$payload" | jq . 2>/dev/null || printf '%s\n' "$payload"
  run_hook "$hook" "$payload"
  echo "==> Exit code: $HOOK_EXIT"
  echo "==> STDOUT:"
  printf '%s\n' "$HOOK_STDOUT"
  echo "==> STDERR:"
  printf '%s\n' "$HOOK_STDERR"
  return "$HOOK_EXIT"
}

# ---- selftest: regression checks doubling as this script's unit tests ----

pass_count=0
fail_count=0

# expect_output <desc> <hook> <payload> <jq-filter over stdout, or "empty">
# "empty" asserts stdout is empty; otherwise stdout must be JSON satisfying
# the jq -e filter. Exit code must always be 0 (Copilot's success contract).
expect_output() {
  local desc="$1" hook="$2" payload="$3" want="$4" ok=1
  run_hook "$hook" "$payload"
  [ "$HOOK_EXIT" -eq 0 ] || ok=0
  if [ "$want" = "empty" ]; then
    [ -z "$HOOK_STDOUT" ] || ok=0
  else
    printf '%s' "$HOOK_STDOUT" | jq -e "$want" >/dev/null 2>&1 || ok=0
  fi
  if [ "$ok" = "1" ]; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (exit $HOOK_EXIT, stdout: ${HOOK_STDOUT:-<empty>})"
    fail_count=$((fail_count + 1))
  fi
}

cmd_selftest() {
  local cwd="$PWD"

  expect_output "edit-guard denies a no-op edit" \
    pre-tool-use-edit-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{sessionId:"selftest", cwd:$cwd, toolName:"edit", toolArgs:{path:"/tmp/x.txt", old_str:"a", new_str:"a"}}')" \
    '.permissionDecision == "deny"'

  expect_output "edit-guard allows a real edit" \
    pre-tool-use-edit-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{sessionId:"selftest", cwd:$cwd, toolName:"edit", toolArgs:{path:"/tmp/x.txt", old_str:"a", new_str:"b"}}')" \
    empty

  local noop_file
  noop_file=$(mktemp)
  printf 'same content' > "$noop_file"
  expect_output "edit-guard denies a no-op create over an identical file" \
    pre-tool-use-edit-guard.sh \
    "$(jq -n --arg cwd "$cwd" --arg f "$noop_file" '{sessionId:"selftest", cwd:$cwd, toolName:"create", toolArgs:{path:$f, file_text:"same content"}}')" \
    '.permissionDecision == "deny"'
  rm -f "$noop_file"

  # loop-breaker: fire the same signature 3x in an isolated session; only the
  # 3rd consecutive call should deny.
  local loop_payload
  loop_payload=$(jq -n --arg cwd "$cwd" '{sessionId:"selftest-loop", cwd:$cwd, toolName:"bash", toolArgs:{command:"echo hi"}}')
  expect_output "loop-breaker allows the 1st call" pre-tool-use-loop-breaker.sh "$loop_payload" empty
  expect_output "loop-breaker allows the 2nd call" pre-tool-use-loop-breaker.sh "$loop_payload" empty
  expect_output "loop-breaker denies the 3rd identical call" pre-tool-use-loop-breaker.sh "$loop_payload" \
    '.permissionDecision == "deny"'

  # user-prompt-submit resets the loop state: after it, two identical calls
  # must pass again.
  expect_output "user-prompt-submit runs cleanly" user-prompt-submit.sh \
    "$(jq -n --arg cwd "$cwd" '{sessionId:"selftest-loop", cwd:$cwd, prompt:"next task please"}')" \
    empty
  expect_output "loop-breaker counter was reset by the new prompt" \
    pre-tool-use-loop-breaker.sh "$loop_payload" empty
  rm -rf "${STATE_HOME:?}/selftest-loop"

  expect_output "stop-gate no-ops without a transcript" \
    agent-stop-goal-check.sh \
    "$(jq -n --arg cwd "$cwd" '{sessionId:"selftest", cwd:$cwd, transcriptPath:"/nonexistent", stopReason:"end_turn"}')" \
    empty

  local transcript stop_payload
  transcript=$(mktemp)
  printf 'user: fix the bug\nGOAL: fix the login bug\nsome tool call\n' > "$transcript"
  stop_payload=$(jq -n --arg cwd "$cwd" --arg t "$transcript" '{sessionId:"selftest-stop", cwd:$cwd, transcriptPath:$t, stopReason:"end_turn"}')
  expect_output "stop-gate blocks a GOAL: without a later GOAL_CHECK:" \
    agent-stop-goal-check.sh "$stop_payload" '.decision == "block"'
  expect_output "stop-gate fires at most once per turn" \
    agent-stop-goal-check.sh "$stop_payload" empty
  rm -rf "${STATE_HOME:?}/selftest-stop"

  printf 'GOAL_CHECK: ACHIEVED\n' >> "$transcript"
  stop_payload=$(jq -n --arg cwd "$cwd" --arg t "$transcript" '{sessionId:"selftest-stop2", cwd:$cwd, transcriptPath:$t, stopReason:"end_turn"}')
  expect_output "stop-gate allows once GOAL_CHECK: follows the GOAL:" \
    agent-stop-goal-check.sh "$stop_payload" empty
  rm -rf "${STATE_HOME:?}/selftest-stop2"
  rm -f "$transcript"

  expect_output "session-start emits a digest as additionalContext" \
    session-start.sh \
    "$(jq -n --arg cwd "$cwd" '{sessionId:"selftest", cwd:$cwd, source:"startup"}')" \
    '.additionalContext | contains("Project digest") and contains("GOAL_CHECK")'

  expect_output "session-end-cleanup runs cleanly" session-end-cleanup.sh '{}' empty

  rm -rf "${STATE_HOME:?}/selftest"

  echo "---"
  echo "$pass_count passed, $fail_count failed"
  [ "$fail_count" -eq 0 ]
}

case "${1:-}" in
  list) cmd_list ;;
  run) shift; cmd_run "$@"; exit $? ;;
  selftest) cmd_selftest; exit $? ;;
  -h | --help | "") usage ;;
  *) usage >&2; exit 2 ;;
esac
