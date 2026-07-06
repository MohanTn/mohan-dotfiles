#!/usr/bin/env bash
# SessionStart — 1.3 session/project digest, keyed by cwd since there's no single user-level CLAUDE.md
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

proj_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$proj_cwd" ] && proj_cwd="$PWD"

digest_dir="$HOOKS_STATE_HOME/digests"
mkdir -p "$digest_dir" 2>/dev/null
key=$(printf '%s' "$proj_cwd" | md5sum | cut -d' ' -f1)
digest="$digest_dir/${key}.md"
claude_md="$proj_cwd/CLAUDE.md"

needs_regen=0
if [ ! -f "$digest" ]; then
  needs_regen=1
elif [ -f "$claude_md" ] && [ "$claude_md" -nt "$digest" ]; then
  needs_regen=1
elif [ ! -f "$claude_md" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$digest" 2>/dev/null || echo 0) ))
  [ "$age" -gt 86400 ] && needs_regen=1
fi

if [ "$needs_regen" = "1" ]; then
  {
    echo "## Project digest for: $proj_cwd"
    if [ -f "$claude_md" ]; then
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
    echo "### Top-level entries"
    ls -1 "$proj_cwd" 2>/dev/null | head -20
  } > "$digest" 2>/dev/null
  log "session-start: regenerated digest for $proj_cwd"
fi

cat "$digest" 2>/dev/null
exit 0
