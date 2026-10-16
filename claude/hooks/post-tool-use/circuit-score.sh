#!/usr/bin/env bash
# PostToolUse: Edit|Write — scores the diff against the turn's stated GOAL:
# line using the circuit-1.7b System-One judge (see /home/mohan/REPO/circuit),
# and appends one JSONL row per edit to $state_dir/circuit_scores.jsonl for
# session-analytics.py / session-web.py to read.
#
# Never blocks the edit: circuit_healthy's budget is ~2s and the /v1/systemone
# call itself is capped at 3s, both well under this hook's timeout in
# claude/settings.json, and a cold/unreachable/erroring model always still
# exits 0. The one deliberate exception is a genuinely low score (feature-plan
# decision q-2: also warn, don't just log) — that is a non-blocking exit 2,
# the same posture as secret-post-guard.sh: the edit already happened, this
# only gets Claude to re-check the diff against the goal in the same turn.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$file" ] && exit 0

log_file="$state_dir/circuit_scores.jsonl"

# log_row status [score_json] [goal]
log_row() {
  local status="$1" score="${2:-null}" goal="${3:-}"
  jq -nc --arg file "$file" --arg goal "$goal" --arg status "$status" \
    --arg ts "$(printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)" --argjson score "$score" \
    '{file:$file, goal:(if $goal=="" then null else $goal end), score:$score, status:$status, ts:$ts}' \
    >> "$log_file" 2>/dev/null
}

# Keep the model warm for next time; never wait on it here — this call races
# in the background regardless of whether the health check below passes.
bash "$HOOKS_HOME/tools/circuit-daemon.sh" >/dev/null 2>&1 &
disown

if ! circuit_healthy 2; then
  log_row "cold"
  exit 0
fi

goal=$(tail -n 200 "$transcript" 2>/dev/null | grep -oE 'GOAL: .*' | tail -n1)
diff=$(git -C "$(dirname "$file")" diff -- "$file" 2>/dev/null | head -c 4000)
[ -z "$diff" ] && diff="(no git diff available for $file)"

body=$(jq -nc --arg goal "${goal:-(no explicit goal stated)}" --arg diff "$diff" --arg model "$CIRCUIT_MODEL" \
  '{state: {goal: $goal, diff: $diff}, model: $model,
    questions: {meets_goal: {type: "noul",
      instructions: "Does this code change correctly implement the stated goal, with no missing error handling or wrong logic?"}}}')

resp=$(curl -s -m 3 -w $'\n%{http_code}' "$CIRCUIT_URL/v1/systemone" \
  -H 'Authorization: Bearer local' -H 'Content-Type: application/json' \
  -d "$body" 2>/dev/null)
curl_rc=$?

if [ "$curl_rc" != "0" ] || [ -z "$resp" ]; then
  log_row "unreachable" null "$goal"
  exit 0
fi

http_code=$(printf '%s' "$resp" | tail -n1)
json=$(printf '%s' "$resp" | sed '$d')

if [ "$http_code" = "401" ]; then
  # Don't spam the log every edit on a misconfigured session — once is enough
  # to point at the problem.
  marker="$state_dir/circuit_auth_error_logged"
  [ -f "$marker" ] && exit 0
  : > "$marker" 2>/dev/null
  log_row "auth_error" null "$goal"
  exit 0
fi

score=$(printf '%s' "$json" | jq -r '.answers.meets_goal.noul // empty' 2>/dev/null)
if [ -z "$score" ]; then
  log_row "error" null "$goal"
  exit 0
fi

if [ -z "$goal" ]; then
  log_row "no_goal" "$score" ""
  exit 0
fi

log_row "ok" "$score" "$goal"

low=$(jq -n --argjson s "$score" '$s < 0.7')
if [ "$low" = "true" ]; then
  log "circuit-score: low confidence ($score) for $file against goal: $goal"
  cat >&2 <<MSG
circuit scored this edit's goal-match at $score (below 0.7) for $file.
Re-read the diff against the stated goal before reporting done, and verify
it actually runs — a low score means the judge is unsure it matches, not
that it is provably wrong.
MSG
  exit 2
fi

exit 0
