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
