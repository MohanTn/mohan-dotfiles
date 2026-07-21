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
  [session-start.sh]="SessionStart::regenerate .claude/repo-map.md (via repo-map.sh) + print the digest that points at it"
  [user-prompt-submit.sh]="UserPromptSubmit::clear prior loop/goal state, hint the MCP reader for @-referenced documents"
  [boilerplate-hint.sh]="UserPromptSubmit::point at ~/.agents/boilerplats/scaffold.js on boilerplate-flavored prompts"
  [pre-tool-use-edit-guard.sh]="PreToolUse (Edit/Write)::block no-op edits/writes"
  [boilerplate-guard.sh]="PreToolUse (Edit/Write)::mandate scaffold.js for new boilerplate files, protect scaffold:inject markers"
  [pre-tool-use-goal-capture.sh]="PreToolUse (*)::capture the stated GOAL: line from the transcript"
  [pre-tool-use-loop-breaker.sh]="PreToolUse (*)::block 3rd consecutive identical tool call"
  [post-tool-use-edit.sh]="PostToolUse (Edit/Write)::resolve new relative imports after edits"
  [pre-compact.sh]="PreCompact::replay goal + files edited + diffstat across a compaction"
  [stop-goal-check.sh]="Stop::advisory-only; log if GOAL_CHECK: was never stated (never blocks)"
  [session-end-cleanup.sh]="SessionEnd::prune stale hook state"
  [session-end-audit.sh]="SessionEnd::auto-generate the session audit file (system layer + hook inventory + trace)"
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
    boilerplate-hint.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"UserPromptSubmit", prompt:"create a new repository class for Orders"}'
      ;;
    pre-tool-use-edit-guard.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Edit",
          tool_input:{file_path:"/tmp/example.txt", old_string:"same text", new_string:"same text"}}'
      ;;
    boilerplate-guard.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Write",
          tool_input:{file_path:"/tmp/does-not-exist/OrdersController.cs", content:"public class OrdersController {}"}}'
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
    pre-compact.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"PreCompact", trigger:"auto"}'
      ;;
    session-end-cleanup.sh | session-end-audit.sh)
      jq -n --arg sid "$TEST_SESSION_ID" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionEnd", reason:"exit", transcript_path:"/nonexistent/transcript.jsonl"}'
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

# Trailing arguments after the needle are passed through to the hook script
# (session-start.sh takes --no-claude-md).
expect_contains() {
  local desc="$1" hook="$2" payload="$3" needle="$4" out
  shift 4
  out=$(printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" "$@" 2>/dev/null)
  if printf '%s' "$out" | grep -qF "$needle"; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (output did not contain: $needle)"
    fail_count=$((fail_count + 1))
  fi
}

expect_not_contains() {
  local desc="$1" hook="$2" payload="$3" needle="$4" out
  shift 4
  out=$(printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" "$@" 2>/dev/null)
  if printf '%s' "$out" | grep -qF "$needle"; then
    echo "FAIL: $desc (output unexpectedly contained: $needle)"
    fail_count=$((fail_count + 1))
  else
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
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

# expect_cond <desc> <cmd...> — passes when the command exits 0. For asserting
# on a hook's side effects (state files it writes) rather than its output.
expect_cond() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc"
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

  # pre-compact: silent with no carry-forward state, emits the edited-file list once there is some
  expect_empty "pre-compact stays silent with nothing to carry forward" \
    pre-compact.sh \
    "$(jq -n '{session_id:"selftest-precompact", cwd:"/tmp/nonexistent", hook_event_name:"PreCompact"}')"
  local pc_dir="$STATE_HOME/selftest-precompact"
  mkdir -p "$pc_dir"
  printf '/tmp/one.ts\n/tmp/one.ts\n/tmp/two.ts\n' > "$pc_dir/edited_files"
  expect_contains "pre-compact replays files edited this session" \
    pre-compact.sh \
    "$(jq -n '{session_id:"selftest-precompact", cwd:"/tmp/nonexistent", hook_event_name:"PreCompact"}')" \
    "/tmp/two.ts"
  rm -rf "$pc_dir"

  expect_exit "boilerplate-guard blocks a hand-written new controller" \
    boilerplate-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, tool_name:"Write", tool_input:{file_path:"/tmp/does-not-exist/OrdersController.cs", content:"public class OrdersController {}"}}')" \
    2

  expect_exit "boilerplate-guard allows a scaffold-marked write" \
    boilerplate-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, tool_name:"Write", tool_input:{file_path:"/tmp/does-not-exist/OrdersController.cs", content:"public class OrdersController {\n    // scaffold:inject\n}"}}')" \
    0

  expect_exit "boilerplate-guard ignores non-boilerplate files" \
    boilerplate-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, tool_name:"Write", tool_input:{file_path:"/tmp/does-not-exist/notes.md", content:"hello"}}')" \
    0

  expect_exit "boilerplate-guard blocks an edit that removes the marker" \
    boilerplate-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, tool_name:"Edit", tool_input:{file_path:"/tmp/does-not-exist/OrdersController.cs", old_string:"    // scaffold:inject\n}", new_string:"}"}}')" \
    2

  expect_exit "boilerplate-guard allows an ordinary edit to a boilerplate file" \
    boilerplate-guard.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, tool_name:"Edit", tool_input:{file_path:"/tmp/does-not-exist/OrdersController.cs", old_string:"throw new NotImplementedException();", new_string:"return Ok();"}}')" \
    0

  # overwrite rules need a real file: marked file loses marker -> block, keeps marker -> allow
  local guard_dir guard_file
  guard_dir=$(mktemp -d)
  guard_file="$guard_dir/OrdersController.cs"
  printf 'public class OrdersController {\n    // scaffold:inject\n}\n' > "$guard_file"
  expect_exit "boilerplate-guard blocks an overwrite that drops the marker" \
    boilerplate-guard.sh \
    "$(jq -n --arg cwd "$cwd" --arg f "$guard_file" '{session_id:"selftest", cwd:$cwd, tool_name:"Write", tool_input:{file_path:$f, content:"public class OrdersController {}"}}')" \
    2
  expect_exit "boilerplate-guard allows an overwrite that keeps the marker" \
    boilerplate-guard.sh \
    "$(jq -n --arg cwd "$cwd" --arg f "$guard_file" '{session_id:"selftest", cwd:$cwd, tool_name:"Write", tool_input:{file_path:$f, content:"public class OrdersController {\n    // scaffold:inject\n}"}}')" \
    0
  rm -rf "$guard_dir"

  expect_contains "boilerplate-hint fires on an endpoint-flavored prompt" \
    boilerplate-hint.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, prompt:"create a new TradeNotes endpoint for CRUD"}')" \
    "scaffold.js"

  expect_contains "boilerplate-hint fires on a matching prompt" \
    boilerplate-hint.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, prompt:"create a new repository class for Orders"}')" \
    "scaffold.js"

  expect_empty "boilerplate-hint stays silent on an unrelated prompt" \
    boilerplate-hint.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, prompt:"why is the login test flaky"}')"

  expect_exit "session-end-audit exits 0 even when transcript is missing" \
    session-end-audit.sh \
    "$(jq -n --arg cwd "$cwd" '{session_id:"selftest", cwd:$cwd, hook_event_name:"SessionEnd", reason:"exit", transcript_path:"/nonexistent/transcript.jsonl"}')" \
    0

  # ---- post-tool-use-edit.sh ----
  # A blocking gate (exit 2) that had no coverage at all. It reads new `+import`
  # lines out of `git diff`, so the import must be an uncommitted change against
  # a committed baseline — a bare file in a temp dir exercises nothing.
  local pte_dir pte_payload
  pte_dir=$(mktemp -d)
  git -C "$pte_dir" init -q
  git -C "$pte_dir" config user.email selftest@example.com
  git -C "$pte_dir" config user.name selftest
  : > "$pte_dir/app.ts"
  git -C "$pte_dir" add app.ts
  git -C "$pte_dir" commit -qm baseline
  printf 'import { helper } from "./helper.js";\n' > "$pte_dir/app.ts"
  pte_payload=$(jq -n --arg f "$pte_dir/app.ts" \
    '{session_id:"selftest-postedit", cwd:"/tmp", tool_name:"Edit", tool_input:{file_path:$f}}')

  expect_exit "post-tool-use-edit blocks an import resolving to nothing" \
    post-tool-use-edit.sh "$pte_payload" 2

  # NodeNext/ESM: a "./helper.js" specifier is satisfied by helper.ts, which is
  # exactly the case the extension-stripping in the hook exists for.
  printf 'export const helper = 1;\n' > "$pte_dir/helper.ts"
  expect_exit "post-tool-use-edit allows a .js specifier resolved by a .ts file" \
    post-tool-use-edit.sh "$pte_payload" 0

  expect_exit "post-tool-use-edit ignores a non-TypeScript file" \
    post-tool-use-edit.sh \
    "$(jq -n --arg f "$pte_dir/notes.md" '{session_id:"selftest-postedit", cwd:"/tmp", tool_name:"Write", tool_input:{file_path:$f}}')" \
    0

  # 2.1 ledger: pre-compact.sh replays edited_files, so the writer needs its own
  # assertion — a silent regression here only shows up after a compaction.
  expect_cond "post-tool-use-edit records the file in the edited_files ledger" \
    grep -qF "$pte_dir/app.ts" "$STATE_HOME/selftest-postedit/edited_files"
  expect_cond "post-tool-use-edit advances the edit generation counter" \
    test -s "$STATE_HOME/selftest-postedit/edit_gen"
  rm -rf "$pte_dir" "${STATE_HOME:?}/selftest-postedit"

  # ---- pre-tool-use-goal-capture.sh ----
  local gc_transcript gc_payload
  gc_transcript=$(mktemp)
  jq -nc '{type:"user", message:{role:"user", content:"do the thing"}}' > "$gc_transcript"
  jq -nc '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"GOAL: prove the capture works"}]}}' >> "$gc_transcript"
  gc_payload=$(jq -n --arg t "$gc_transcript" \
    '{session_id:"selftest-goal", cwd:"/tmp", tool_name:"Bash", tool_input:{command:"true"}, transcript_path:$t}')
  run_hook pre-tool-use-goal-capture.sh "$gc_payload" >/dev/null 2>&1
  expect_cond "goal-capture stores the GOAL line stated after the last user turn" \
    grep -qxF "prove the capture works" "$STATE_HOME/selftest-goal/goal.txt"
  rm -rf "${STATE_HOME:?}/selftest-goal"

  # The scan is deliberately scoped to text after the newest user message, so a
  # GOAL: from an earlier turn must not be picked up as this turn's goal.
  jq -nc '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"GOAL: a stale goal from an earlier turn"}]}}' > "$gc_transcript"
  jq -nc '{type:"user", message:{role:"user", content:"now do something else"}}' >> "$gc_transcript"
  run_hook pre-tool-use-goal-capture.sh \
    "$(jq -n --arg t "$gc_transcript" '{session_id:"selftest-stale", cwd:"/tmp", tool_name:"Bash", tool_input:{command:"true"}, transcript_path:$t}')" \
    >/dev/null 2>&1
  expect_cond "goal-capture ignores a GOAL line predating the last user turn" \
    test ! -f "$STATE_HOME/selftest-stale/goal.txt"
  rm -f "$gc_transcript"
  rm -rf "${STATE_HOME:?}/selftest-stale"

  # ---- user-prompt-submit.sh ----
  expect_contains "user-prompt-submit hints the MCP reader for an @-referenced pdf" \
    user-prompt-submit.sh \
    "$(jq -n '{session_id:"selftest-ups", cwd:"/tmp", prompt:"summarise @docs/spec.pdf for me"}')" \
    "mcp__files-mcp__convert_file"

  expect_empty "user-prompt-submit stays silent on a prompt with no documents" \
    user-prompt-submit.sh \
    "$(jq -n '{session_id:"selftest-ups", cwd:"/tmp", prompt:"why is the login test flaky"}')"

  # Per-turn reset: a goal left over from the previous turn must not survive into
  # the next one, or stop-goal-check gates against a goal nobody restated.
  mkdir -p "$STATE_HOME/selftest-ups"
  printf 'stale goal' > "$STATE_HOME/selftest-ups/goal.txt"
  run_hook user-prompt-submit.sh \
    "$(jq -n '{session_id:"selftest-ups", cwd:"/tmp", prompt:"a fresh prompt"}')" >/dev/null 2>&1
  expect_cond "user-prompt-submit clears the previous turn's captured goal" \
    test ! -f "$STATE_HOME/selftest-ups/goal.txt"
  rm -rf "${STATE_HOME:?}/selftest-ups"

  # ---- repo-map.sh + session-start.sh ----
  # repo-map.sh is not a stdin hook (it takes a root as $1) but session-start.sh
  # is a thin wrapper over it, so both are covered off one temp repo.
  local map_dir map_out
  map_dir=$(mktemp -d)
  git -C "$map_dir" init -q
  printf 'def login(user):\n    return True\n' > "$map_dir/auth.py"
  printf '# Project\nnotes\n' > "$map_dir/CLAUDE.md"
  git -C "$map_dir" add auth.py CLAUDE.md
  map_out=$(bash "$HOOKS_DIR/repo-map.sh" "$map_dir" 2>/dev/null)
  expect_cond "repo-map writes the map and returns its path" \
    test -n "$map_out" -a -f "$map_out"
  expect_cond "repo-map lists the tracked file" \
    grep -qF "auth.py" "$map_dir/.claude/repo-map.md"
  expect_cond "repo-map extracts symbols via ctags" \
    grep -qF "login (function)" "$map_dir/.claude/repo-map.md"

  local ss_payload
  ss_payload=$(jq -n --arg cwd "$map_dir" \
    '{session_id:"selftest-start", cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}')
  expect_contains "session-start points at the generated repo map" \
    session-start.sh "$ss_payload" "Repo map — read this before searching"

  # Claude Code injects project CLAUDE.md itself, so --no-claude-md must drop
  # that section; Copilot and Pi omit the flag and rely on it being there.
  expect_contains "session-start includes CLAUDE.md without the flag" \
    session-start.sh "$ss_payload" "### CLAUDE.md"
  expect_not_contains "session-start omits CLAUDE.md under --no-claude-md" \
    session-start.sh "$ss_payload" "### CLAUDE.md" --no-claude-md
  rm -rf "$map_dir" "${STATE_HOME:?}/selftest-start"

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
