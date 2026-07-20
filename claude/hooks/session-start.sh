#!/usr/bin/env bash
# SessionStart — regenerate the repo map and print a short project digest that
# points at it, so the agent can skip the usual fd/rg/Glob orientation pass.
#
# Usage: session-start.sh [--no-claude-md]
#   --no-claude-md  omit the CLAUDE.md excerpt. Claude Code already injects
#                   project CLAUDE.md itself, so repeating it here is pure
#                   duplication; Copilot and Pi load only the global
#                   instructions file, so for them this hook is the only path
#                   by which a project's CLAUDE.md arrives and they omit the flag.
#
# No digest cache: repo-map.sh regenerates on every session by design, and the
# remaining sections are a handful of file reads.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

skip_claude_md=0
for arg in "$@"; do
  [ "$arg" = "--no-claude-md" ] && skip_claude_md=1
done

proj_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$proj_cwd" ] && proj_cwd="$PWD"

claude_md="$proj_cwd/CLAUDE.md"
map_path=$(bash "$HOOKS_HOME/repo-map.sh" "$proj_cwd" 2>/dev/null)

echo "## Project digest for: $proj_cwd"

if [ -n "$map_path" ]; then
  echo "### Repo map — read this before searching"
  echo "A folder -> file -> symbol index of this repo was just generated at:"
  echo "  $map_path"
  echo "It lists every tracked file and, for code files, every function/class/method"
  echo "with its line number. Read that one file to orient yourself instead of"
  echo "fanning out over fd/rg/Glob calls. Fall back to search only for what the map"
  echo "does not answer (call sites, string literals, symbols inside a file body)."
  log "session-start: wrote repo map to $map_path"
fi

if [ "$skip_claude_md" = "0" ] && [ -f "$claude_md" ]; then
  echo "### CLAUDE.md (first 15 lines)"
  head -15 "$claude_md"
fi

if [ -f "$proj_cwd/package.json" ]; then
  echo "### package.json scripts"
  jq -r '.name as $n | "name: \($n)", (.scripts // {} | to_entries[] | "  \(.key): \(.value)")' "$proj_cwd/package.json" 2>/dev/null
fi

# .NET projects
csproj=$(find "$proj_cwd" -maxdepth 3 -name "*.csproj" 2>/dev/null | head -5)
if [ -n "$csproj" ]; then
  echo "### .NET projects"
  printf '%s\n' "$csproj" | while read -r p; do
    name=$(basename "$p")
    pkgs=$(grep -oP '(?<=Include=")[^"]+' "$p" 2>/dev/null | head -8 | paste -sd ', ')
    echo "  $name — packages: ${pkgs:-none}"
  done
fi

# Docker Compose
if [ -f "$proj_cwd/docker-compose.yml" ] || [ -f "$proj_cwd/docker-compose.yaml" ]; then
  echo "### docker-compose services"
  yq e '.services | keys | .[]' "$proj_cwd/docker-compose.yml" 2>/dev/null \
    || grep -E '^\s{2}[a-zA-Z]' "$proj_cwd/docker-compose.yml" 2>/dev/null | sed 's/://' | head -10
fi

exit 0
