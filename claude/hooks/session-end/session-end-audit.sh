#!/usr/bin/env bash
# SessionEnd — auto-generate a human-readable audit of the session that just
# ended: system-prompt layer, configured hook inventory (all agents), and the
# full chronological trace (prompts, hook injections, AI responses, tool calls).
# Writes a per-session archive plus a stable latest.md so there is always one
# file to open. Best-effort: never blocks session end.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

audit_dir="$HOME/.claude/audits"
mkdir -p "$audit_dir" 2>/dev/null || exit 0

stamp=$(date +%Y%m%d-%H%M%S)
out="$audit_dir/${stamp}-${session_id}.md"

# Prefer the explicit transcript from the payload; the python falls back to the
# latest session for --cwd if it is missing.
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  python3 "$HOME/.claude/hooks/session-end/session-audit.py" "$transcript" --out "$out" 2>/dev/null
else
  python3 "$HOME/.claude/hooks/session-end/session-audit.py" --cwd "$cwd" --out "$out" 2>/dev/null
fi

if [ -f "$out" ]; then
  cp -f "$out" "$audit_dir/latest.md" 2>/dev/null
  log "session-audit: wrote $out"
  # Bound growth: keep the 30 most recent per-session audits.
  ls -1t "$audit_dir"/*-*.md 2>/dev/null | tail -n +31 | xargs -r rm -f 2>/dev/null
fi

exit 0
