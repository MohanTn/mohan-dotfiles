#!/usr/bin/env bash
# Sourced by every Copilot CLI hook script. Caller must read stdin into
# $input and `export HOOK_INPUT="$input"` BEFORE sourcing this file (stdin
# can only be read once). Sets: input, tool_name, cwd, session_id,
# HOOKS_STATE_HOME, state_dir. Provides: log(), tool_arg(), deny_tool().
# Copilot payloads are camelCase (sessionId, toolName, toolArgs), unlike
# Claude Code's snake_case. Runtime state lives under XDG state, never next
# to the scripts: ~/.copilot/hooks is a read-only Nix store symlink once
# managed by home-manager.
set -uo pipefail   # NOT -e: callers expect non-zero exits from git/jq/grep as normal control flow

input="${HOOK_INPUT:-}"
tool_name=$(printf '%s' "$input" | jq -r '.toolName // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.sessionId // empty' 2>/dev/null)
[ -z "$session_id" ] && session_id="default"

HOOKS_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/copilot-hooks"
state_dir="$HOOKS_STATE_HOME/${session_id}"
mkdir -p "$state_dir" 2>/dev/null || true

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >> "${state_dir}/hook.log" 2>/dev/null || true; }

# The exact toolArgs field names of Copilot's edit/create tools are not part
# of the documented hook contract, so callers probe the plausible spellings:
#   tool_arg '.path // .file_path // .filePath'
tool_arg() {
  printf '%s' "$input" | jq -r ".toolArgs | ($1) // empty" 2>/dev/null
}

# preToolUse deny contract: a JSON decision on stdout with exit 0. Never
# exit non-zero to deny: Copilot treats non-zero (other than 2) preToolUse
# exits as a hook failure that fails closed without this reason text.
deny_tool() {
  jq -n --arg reason "$1" '{permissionDecision: "deny", permissionDecisionReason: $reason}'
}
