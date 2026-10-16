#!/usr/bin/env bash
# Idempotent start-if-needed for the local circuit System-One service
# (circuit-1.7b, see /home/mohan/REPO/circuit). Called from two places:
# session-start.sh (to pre-warm before the first edit) and circuit-score.sh
# (in case the process died mid-session) — both fire it in the background and
# never wait on it, so this script itself must return fast no matter what
# state the model is in. It only ever ensures a process is on its way up; it
# is not the thing that decides whether scoring happens this turn (that is
# circuit_healthy's job, called separately by the caller).
set -uo pipefail
# Always launched from inside session-start.sh or circuit-score.sh, both of
# which already `export HOOK_INPUT` before backgrounding this script — never
# read stdin here, there is nothing new on it and this runs detached.
source "$HOME/.claude/hooks/lib/common.sh"

lock="$HOOKS_STATE_HOME/circuit.pid"

# Already up.
circuit_healthy 1 && exit 0

# Already starting (or running but not answering /healthz yet, e.g. still
# loading weights onto the GPU) — a live PID under the lock means someone
# else's launch is in flight, don't start a second one.
if [ -f "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi

if [ ! -d "$CIRCUIT_REPO_DIR" ]; then
  log "circuit-daemon: CIRCUIT_REPO_DIR ($CIRCUIT_REPO_DIR) not found, skipping"
  exit 0
fi

(
  cd "$CIRCUIT_REPO_DIR" || exit 0
  S1_MODEL="$CIRCUIT_MODEL" nohup uv run python -m s1proto >>"$HOOKS_STATE_HOME/circuit.log" 2>&1 &
  echo $! > "$lock"
  log "circuit-daemon: launched circuit-1.7b (pid $!), warming up"
)
exit 0
