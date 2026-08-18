#!/usr/bin/env bash
# PreToolUse: Bash — closes the shell write-around of the boilerplate mandate.
# boilerplate-guard.sh gates Write/Edit; without this, `cat > file.ts <<EOF`,
# `echo ... >> file.py`, or `tee file.go` would create code files with no gate
# at all. Policy (deterministic, no override): ANY redirection or tee into a
# code file is denied — code files are written through Write/Edit (guarded) or
# through the scaffold generator (exempted below). Reused as-is by the Copilot
# and Pi hook adapters, like boilerplate-guard.sh.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# The generator is the one sanctioned Bash writer of code files.
printf '%s' "$cmd" | grep -q 'boilerplats/scaffold\.js' && exit 0

ext='(cs|ts|tsx|js|jsx|mjs|cjs|py|go)'
redirect_re="(>|>>)[[:space:]]*[\"']?[^[:space:]\"';|&]+\.${ext}[\"']?([[:space:]]|;|&|\||\$)"
tee_re="\btee[[:space:]]+(-a[[:space:]]+)?[\"']?[^[:space:]\"';|&]+\.${ext}[\"']?([[:space:]]|;|&|\||\$)"

# Staging a hand-written file under a harmless extension and renaming it into
# place (printf > x.txt && mv x.txt x.cs) is the same write-around one step
# removed, so a move/copy whose DESTINATION is a code file and whose SOURCE is
# not counts too. Moving code to code (Foo.cs -> Bar.cs) is an ordinary
# refactor and stays allowed: that content already passed the guard once.
mv_re="\b(mv|cp)[[:space:]]+((-[A-Za-z]+|--[a-z-]+)[[:space:]]+)*[\"']?[^[:space:]\"';|&]+\.[A-Za-z0-9]+[\"']?[[:space:]]+[\"']?[^[:space:]\"';|&]+\.${ext}[\"']?([[:space:]]|;|&|\||$)"
if printf '%s\n' "$cmd" | grep -qE "$mv_re" && ! printf '%s\n' "$cmd" | grep -qE "\b(mv|cp)[[:space:]]+((-[A-Za-z]+|--[a-z-]+)[[:space:]]+)*[\"']?[^[:space:]\"';|&]+\.${ext}[\"']?[[:space:]]"; then
  log "bash-write-guard: blocked rename-into-place of a code file"
  cat >&2 <<'MSG'
Blocked: renaming/copying a non-code file into a code file bypasses the boilerplate guard.
Create the file with Write/Edit, or for boilerplate with the scaffold MCP tool
scaffold_create / scaffold_inject (fallback: node ~/.agents/boilerplats/scaffold.js ... --json).
MSG
  exit 2
fi

if printf '%s\n' "$cmd" | grep -qE "$redirect_re" || printf '%s\n' "$cmd" | grep -qE "$tee_re"; then
  log "bash-write-guard: blocked shell write into code file"
  cat >&2 <<'MSG'
Blocked: writing code files via shell redirection/heredoc/tee bypasses the boilerplate guard.
Use the Write/Edit tools, or for boilerplate the scaffold MCP tool scaffold_create / scaffold_inject
(fallback: node ~/.agents/boilerplats/scaffold.js ... --json).
MSG
  exit 2
fi
exit 0
