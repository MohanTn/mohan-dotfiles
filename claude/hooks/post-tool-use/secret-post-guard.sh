#!/usr/bin/env bash
# PostToolUse: Bash|Read — second-layer guardrail. secret-guard.sh (PreToolUse)
# only ever sees a tool CALL before it runs, so it cannot catch a secret VALUE
# that only exists in the RESULT: `cat` of a real secret file, or a Bash/Read
# result that happens to contain something shaped like a live credential no
# matter how the command that produced it was written (an obfuscated env-var
# name, string concatenation, etc. that evades the name-based patterns in
# secret-guard.sh, which only look at code/commands, not at output).
#
# This is detection-and-warn, not prevention: by the time PostToolUse fires,
# the tool has already run and its result already exists in this turn's
# transcript. A block here tells the model to disregard rather than repeat or
# act on the leaked value; it does not retroactively erase it. Treat this as
# a second net with the same mesh size as secret-guard.sh (same
# LEAK_VALUE_PATTERNS, lib/common.sh), not a guarantee nothing leaks — an
# unknown-shaped secret, or output the source deliberately transformed
# (base64, split across lines, reversed) still passes through undetected,
# same as it always could have.
# Reused as-is by the Copilot and Pi hook adapters, like secret-guard.sh —
# NOTE: as of writing this is wired into claude/settings.json only; a Copilot
# or Pi adapter needs its own PostToolUse tool-result payload confirmed
# before pointing it at this script, do not assume the shape matches.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

output=$(printf '%s' "$input" | jq -c '.tool_response // {}' 2>/dev/null)
[ -n "$output" ] && [ "$output" != "null" ] && [ "$output" != "{}" ] || exit 0

# Value shapes only. LEAK_ENV_READ_PATTERNS matches CODE that reads a
# secret-named var (os.environ[...], process.env.X, ...); a tool RESULT is
# data, not source, so those patterns have nothing to match here and would
# only add false-positive risk (e.g. a grep result that quotes such code back).
for p in "${LEAK_VALUE_PATTERNS[@]}"; do
  if printf '%s' "$output" | grep -qE "$p"; then
    log "secret-post-guard: blocked tool result ($tool_name) matching secret pattern"
    cat >&2 <<'MSG'
Blocked: this tool call's OUTPUT looks like a live secret or credential.
It already ran, the result is not undone, but do not repeat, quote, or act
on that value in any later step. Tell the user which command or file
surfaced it so they can rotate the credential, then continue without it.
MSG
    exit 2
  fi
done
exit 0
