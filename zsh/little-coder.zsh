# gcm / mri: commit-message and MR-intent helpers backed by little-coder and
# a local llama.cpp server (see nix/little-coder.nix; opt in via
# ./setup-packages.sh -> enableLittleCoder). Kept bash-compatible so the
# little-coder-helpers flake check can lint and drive it with shellcheck/bash.
#
# Configuration (all optional):
#   LITTLE_CODER_GGUF       GGUF path (default set by nix/little-coder.nix)
#   LITTLE_CODER_MODEL      provider/id handle (default llamacpp/gemma)
#   LITTLE_CODER_CTX        llama-server context size (default 8192)
#   LITTLE_CODER_NGL        layers offloaded to the GPU (-ngl); set by
#                           nix/little-coder.nix only when littleCoderGpu is
#                           on, and left unset for CPU builds
#   LITTLE_CODER_ARGS       extra llama-server flags, word-split
#   LITTLE_CODER_TIMEOUT    seconds to wait for server health (default 30)
#   LITTLE_CODER_NO_SERVER  =1 skips server management (LAN server, tests)

_lc_diff_limit=12000
_lc_health_url="http://127.0.0.1:8888/health"

_lc_ready() {
  if ! command -v little-coder >/dev/null 2>&1; then
    echo "little-coder not installed - enable it in ./setup-packages.sh, then ./setup.sh" >&2
    return 1
  fi
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "not a git repository" >&2
    return 1
  fi
}

_lc_ensure_server() {
  [ "${LITTLE_CODER_NO_SERVER:-0}" = "1" ] && return 0
  local model="${LITTLE_CODER_GGUF:-$HOME/.cache/models/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf}"
  local log="$HOME/.cache/little-coder/llama-server.log"
  local spawned_pid=""

  if ! curl -sf --max-time 2 "$_lc_health_url" >/dev/null 2>&1; then
    if ! command -v llama-server >/dev/null 2>&1; then
      echo "llama-server not installed - enable little-coder in ./setup-packages.sh" >&2
      return 1
    fi
    if [ ! -f "$model" ]; then
      echo "model missing: $model - re-run ./setup.sh or set LITTLE_CODER_GGUF" >&2
      return 1
    fi
    mkdir -p "${log%/*}"
    # -ngl only when a GPU build is configured: passing it to a CPU build is
    # accepted but silently meaningless, and its absence is what tells you
    # from the log which build is actually running.
    local extra_args=""
    [ -n "${LITTLE_CODER_NGL:-}" ] && extra_args="-ngl ${LITTLE_CODER_NGL}"
    # shellcheck disable=SC2086  # both are deliberately word-split flag lists
    llama-server -m "$model" --host 127.0.0.1 --port 8888 --jinja \
      -c "${LITTLE_CODER_CTX:-8192}" $extra_args ${LITTLE_CODER_ARGS:-} >"$log" 2>&1 &
    spawned_pid=$!
    disown 2>/dev/null || true
  fi

  local waited=0 timeout="${LITTLE_CODER_TIMEOUT:-30}"
  until curl -sf --max-time 2 "$_lc_health_url" >/dev/null 2>&1; do
    waited=$((waited + 1))
    if [ "$waited" -ge "$timeout" ]; then
      echo "llama-server not healthy after ${timeout}s; last log lines:" >&2
      [ -f "$log" ] && tail -5 "$log" >&2
      [ -n "$spawned_pid" ] && kill "$spawned_pid" 2>/dev/null
      return 1
    fi
    sleep 1
  done
}

# $1 = task prompt; diff on stdin, truncated so a huge diff can't blow the
# small model's context window.
_lc_generate() {
  local diff
  diff="$(cat)"
  if [ "${#diff}" -gt "$_lc_diff_limit" ]; then
    diff="${diff:0:$_lc_diff_limit}
[diff truncated]"
  fi
  little-coder --model "${LITTLE_CODER_MODEL:-llamacpp/gemma}" --no-update-check \
    -p "$1

$diff"
}

gcm() {
  _lc_ready || return 1
  if git diff --cached --quiet; then
    echo "nothing staged" >&2
    return 1
  fi
  _lc_ensure_server || return 1
  git diff --cached | _lc_generate \
    "Write a conventional commit message (type(scope): subject, subject <=72 chars, optional short body) for the following staged diff. Output only the commit message, nothing else."
}

mri() {
  _lc_ready || return 1
  local base diff
  if ! base="$(git merge-base main HEAD 2>/dev/null)"; then
    echo "cannot find merge-base with main" >&2
    return 1
  fi
  diff="$(git diff "$base"..HEAD)"
  if [ -z "$diff" ]; then
    echo "no changes vs main" >&2
    return 1
  fi
  _lc_ensure_server || return 1
  printf '%s' "$diff" | _lc_generate \
    "Summarize the intent of this merge request in 2-4 sentences: what changes and why. Output only the summary, nothing else."
}
