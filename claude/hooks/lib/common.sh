#!/usr/bin/env bash
# Sourced by every hook script. Caller must read stdin into $input and
# `export HOOK_INPUT="$input"` BEFORE sourcing this file (stdin can only be
# read once). Sets: input, tool_name, cwd, session_id, HOOKS_HOME,
# HOOKS_STATE_HOME, state_dir. Provides: log().
# Runtime state lives under XDG state, not under HOOKS_HOME: the hooks dir is
# a read-only Nix store symlink once managed by home-manager.
set -uo pipefail   # NOT -e: callers expect non-zero exits from git/jq/grep as normal control flow

input="${HOOK_INPUT:-}"
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$session_id" ] && session_id="default"

HOOKS_HOME="$HOME/.claude/hooks"
HOOKS_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks"
state_dir="$HOOKS_STATE_HOME/${session_id}"
mkdir -p "$state_dir" 2>/dev/null || true

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >> "${state_dir}/hook.log" 2>/dev/null || true; }

# --- .ai-memory routing ---------------------------------------------------
# Optional per-project persistent memory (see the llm-memory repo): a repo
# that grows a .ai-memory/manifest.json gets prompt-time diagram injection
# for free, via inject-memory.sh. Repos without .ai-memory/ are untouched —
# every caller of ai_memory_match_route treats "no manifest" as a plain no-op.
ai_memory_root() {
  git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${cwd:-.}"
}

# The manifest's diagram for prompt $1. Two schemas, checked in this order:
#   {"diagram": "..."}  — one diagram for the whole repo, returned for EVERY
#                         prompt, no keyword matching. The current shape.
#   {"routes": [...]}   — legacy: highest-priority route whose keywords appear
#                         (case-insensitive, substring) in $1.
# Empty stdout, non-zero return if there is no .ai-memory/manifest.json or
# nothing matches.
ai_memory_match_route() {
  local text="$1" manifest match
  manifest="$(ai_memory_root)/.ai-memory/manifest.json"
  [ -f "$manifest" ] || return 1
  match=$(jq -r --arg text "$text" '
    if (.diagram // "") != "" then .diagram else
    ($text | ascii_downcase) as $t
    | (.routes // [])
    | map(select(.keywords as $k | $k | any(. as $kw | $t | contains($kw | ascii_downcase))))
    | sort_by(.priority // 0) | reverse | .[0].file // empty
    end
  ' "$manifest" 2>/dev/null)
  [ -n "$match" ] || return 1
  printf '%s\n' "$match"
}

# --- secret-shaped patterns --------------------------------------------------
# Single source of truth for both PreToolUse's secret-guard.sh (scans a tool
# CALL before it runs: command text, or Write/Edit content) and PostToolUse's
# secret-post-guard.sh (scans a Bash/Read RESULT after it ran, which
# secret-guard.sh structurally cannot see). One array here so the two layers
# never drift apart the way a second hand-copied list would.
# Tight, low-false-positive shapes for live credentials. Each pattern's
# required literal run is broken up by a regex metachar in this very file, so
# the pattern source never matches itself when this file is the tool input
# (e.g. being written or edited).
LEAK_VALUE_PATTERNS=(
  'AKIA[0-9A-Z]{16}'
  '\-\-\-\-\-BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY\-\-\-\-\-'
  'gh[pousr]_[A-Za-z0-9]{36,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk-[A-Za-z0-9]{20,}'
)

# Workaround shapes: none of the above catch a secret's VALUE when a tool
# call only ever handles its NAME, e.g. an echo of a secret-named shell
# variable (secret-guard.sh sees the command text, not the expanded stdout,
# that gap is what secret-post-guard.sh is for), or a Python/JS/Go/C# script
# that reads a secret-named env var and prints it, then gets run through the
# interpreter. Since there is no network tool on the Bash allowlist, the only
# place a read secret can go is stdout captured back into this conversation,
# so gate at the READ, in code being written OR in an inlined `-c` command,
# rather than trying to prove a print follows it. Deliberately narrow trigger
# words (not bare KEY/API, which are common non-secret names) to keep false
# positives low. NOTE: do not spell out a literal example of the shell shape
# in this comment (a real "dollar sign followed by a SECRET-ish name") or it
# self-matches the pattern below the next time this file itself is edited.
# Only meaningful against CODE (a call or file content), never against a
# RESULT, so secret-post-guard.sh does not use this array.
LEAK_ENV_NAME_RX='[A-Za-z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|API_KEY|ACCESS_KEY|PRIVATE_KEY)[A-Za-z0-9_]*'
# Callers scan jq -c output: every '"' inside a scanned string (Bash command
# or Write/Edit content) comes through backslash-escaped as \", so every
# quote these patterns look for must tolerate one leading backslash.
LEAK_ENV_READ_PATTERNS=(
  "\\\$\\{?${LEAK_ENV_NAME_RX}\\}?"                                          # shell: $VAR / ${VAR}
  "os\\.(environ(\\.get)?\\[?\\(?|getenv\\()\\s*\\\\?['\"]${LEAK_ENV_NAME_RX}" # python
  "process\\.env(\\.|\\[\\\\?['\"]?)${LEAK_ENV_NAME_RX}"                     # javascript/typescript
  "os\\.Getenv\\(\\s*\\\\?\"${LEAK_ENV_NAME_RX}"                             # go
  "Environment\\.GetEnvironmentVariable\\(\\s*\\\\?\"${LEAK_ENV_NAME_RX}"    # csharp
)
