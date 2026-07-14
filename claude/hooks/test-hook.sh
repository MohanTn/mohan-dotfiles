#!/usr/bin/env bash
# test-hook.sh — manually invoke a hook script the same way Claude Code does:
# a JSON payload piped on stdin, nothing else. Reports exit code, stdout, and
# stderr so a hook's behavior can be checked without needing a live session.
#
# Usage:
#   test-hook.sh list                         list hooks with their event + default payload
#   test-hook.sh run <hook.sh> [payload.json]  run a hook (default payload if omitted)
#   echo '{"...":"..."}' | test-hook.sh run <hook.sh> -   run with a custom payload on stdin
#   test-hook.sh selftest                      run the built-in regression checks
#
# Exit code meaning, per Claude Code's hook contract: 0 = allow/continue,
# 2 = block (stderr is fed back to Claude), anything else = non-blocking
# error shown only to the user.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks"
TEST_SESSION_ID="manual-test"

# hook basename -> "event_name::one-line purpose"
declare -A HOOK_INFO=(
  [session-start.sh]="SessionStart::regenerate + print the project digest"
  [user-prompt-submit.sh]="UserPromptSubmit::inject GOAL reminder, clear prior loop/goal state"
  [pre-tool-use-edit-guard.sh]="PreToolUse (Edit/Write)::block no-op edits/writes"
  [pre-tool-use-goal-capture.sh]="PreToolUse (*)::capture the stated GOAL: line from the transcript"
  [pre-tool-use-loop-breaker.sh]="PreToolUse (*)::block 3rd consecutive identical tool call"
  [post-tool-use-edit.sh]="PostToolUse (Edit/Write)::import/type-check/build/sonar-lite gate after edits"
  [stop-goal-check.sh]="Stop::block stop until GOAL_CHECK: was stated"
  [session-end-cleanup.sh]="SessionEnd::prune stale hook state"
)

default_payload() {
  local hook="$1" cwd="$PWD"
  case "$hook" in
    session-start.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}'
      ;;
    user-prompt-submit.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"UserPromptSubmit", prompt:"Please investigate and fix the login bug"}'
      ;;
    pre-tool-use-edit-guard.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Edit",
          tool_input:{file_path:"/tmp/example.txt", old_string:"same text", new_string:"same text"}}'
      ;;
    pre-tool-use-goal-capture.sh | pre-tool-use-loop-breaker.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Bash",
          tool_input:{command:"echo hi"}, transcript_path:"/nonexistent/transcript.jsonl"}'
      ;;
    post-tool-use-edit.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Edit",
          tool_input:{file_path:"/tmp/example.md"}}'
      ;;
    stop-goal-check.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"Stop", transcript_path:"/nonexistent/transcript.jsonl", stop_hook_active:false}'
      ;;
    session-end-cleanup.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionEnd", reason:"exit"}'
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
    printf '%-28s %-28s %s\n' "$hook" "$event" "$purpose"
  done
}

# run_hook <hook.sh> <payload-json-string>  -> prints report, returns hook's exit code
run_hook() {
  local hook="$1" payload="$2" hook_path
  if [[ "$hook" == */* ]]; then
    hook_path="$hook"
  else
    hook_path="$HOOKS_DIR/$hook"
  fi

  if [ ! -f "$hook_path" ]; then
    echo "No such hook script: $hook_path" >&2
    return 127
  fi

  if command -v jq >/dev/null 2>&1 && ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    echo "Payload is not valid JSON:" >&2
    printf '%s\n' "$payload" >&2
    return 1
  fi

  echo "==> Running: $hook_path"
  echo "==> Payload:"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq . 2>/dev/null || printf '%s\n' "$payload"
  else
    printf '%s\n' "$payload"
  fi

  local stdout_file stderr_file exit_code
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  printf '%s' "$payload" | bash "$hook_path" >"$stdout_file" 2>"$stderr_file"
  exit_code=$?

  echo "==> Exit code: $exit_code"
  echo "==> STDOUT:"
  cat "$stdout_file"
  echo "==> STDERR:"
  cat "$stderr_file"

  rm -f "$stdout_file" "$stderr_file"
  return "$exit_code"
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

  run_hook "$hook" "$payload"
}

# ---- selftest: regression checks doubling as this script's unit tests ----

pass_count=0
fail_count=0

expect_exit() {
  local desc="$1" hook="$2" payload="$3" want="$4" got
  run_hook "$hook" "$payload" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    echo "PASS: $desc (exit $got)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected exit $want, got $got)"
    fail_count=$((fail_count + 1))
  fi
}

expect_contains() {
  local desc="$1" hook="$2" payload="$3" needle="$4" out
  out=$(printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" 2>/dev/null)
  if printf '%s' "$out" | grep -qF "$needle"; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (output did not contain: $needle)"
    fail_count=$((fail_count + 1))
  fi
}

expect_empty() {
  local desc="$1" hook="$2" payload="$3" out
  out=$(printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" 2>/dev/null)
  if [ -z "$out" ]; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected empty output, got: $out)"
    fail_count=$((fail_count + 1))
  fi
}

cmd_selftest() {
  local cwd="$PWD"

  expect_exit "edit-guard blocks a no-op edit" \
    pre-tool-use-edit-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, tool_name:"Edit", tool_input:{file_path:"/tmp/x.txt", old_string:"a", new_string:"a"}}')" \
    2

  expect_exit "edit-guard allows a real edit" \
    pre-tool-use-edit-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, tool_name:"Edit", tool_input:{file_path:"/tmp/x.txt", old_string:"a", new_string:"b"}}')" \
    0

  # loop-breaker: fire the same signature 3x in an isolated session, only the
  # 3rd consecutive call should block.
  local loop_payload
  loop_payload=$(jq -n --arg cwd "$cwd" '{session_id:"selftest-loop", cwd:$cwd, tool_name:"Bash", tool_input:{command:"echo hi"}}')
  run_hook pre-tool-use-loop-breaker.sh "$loop_payload" >/dev/null 2>&1
  run_hook pre-tool-use-loop-breaker.sh "$loop_payload" >/dev/null 2>&1
  expect_exit "loop-breaker blocks the 3rd identical call" \
    pre-tool-use-loop-breaker.sh "$loop_payload" 2
  rm -rf "${STATE_HOME:?}/selftest-loop"

  expect_exit "stop-goal-check no-ops with no captured goal" \
    stop-goal-check.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, transcript_path:"/nonexistent", stop_hook_active:false}')" \
    0

  expect_exit "session-end-cleanup runs cleanly" \
    session-end-cleanup.sh '{}' 0

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
