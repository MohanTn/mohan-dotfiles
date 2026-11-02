#!/usr/bin/env bash
# SessionStart: map the repo to an aicode-mcp template.
#
# Runs `aicode-mcp init --quiet` at the git root of the session cwd. init keeps
# any template a project.json or .toolkit/settings.yaml already names,
# otherwise it writes the --template given here and copies the bundled
# templates/ into the repo. It never overwrites existing files, and --quiet
# skips .mcp.json because aicode-mcp.sh registers the servers user-wide.
#
# Only runs where the templates fit, so other repos are never littered:
#   - the repo already has .toolkit/settings.yaml (opted in), or
#   - it tracks a .csproj/.sln/.slnx (--template dotnet-api), or
#   - its root package.json depends on react (--template react-web).
# A .NET or React repo not opted in that already tracks more than
# BROWNFIELD_MIN_SOURCES source files is brownfield: init is skipped and the
# user is told once per repo to run the repo-template skill instead.
#
# Prints one user-facing line only when init created or copied something.
# Silent when aicode-mcp is not installed (enableAicodeMcp is optional).
#
# Usage: aicode-init.sh [--claude]
#   --claude  wrap the line as Claude Code SessionStart JSON: systemMessage so
#             the user sees it, additionalContext so the agent knows too.
#
# Always exits 0.
input=$(cat)

as_claude=0
for arg in "$@"; do
  [ "$arg" = "--claude" ] && as_claude=1
done

# A repo tracking more source files than this is brownfield.
BROWNFIELD_MIN_SOURCES=10

emit() {
  if [ "$as_claude" = "1" ]; then
    jq -n --arg m "$1" \
      '{systemMessage: $m, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
  else
    printf '%s\n' "$1"
  fi
}

command -v aicode-mcp >/dev/null 2>&1 || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"
[ -d "$cwd" ] || exit 0
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0

template=()
if [ ! -f "$root/.toolkit/settings.yaml" ]; then
  if [ -n "$(git -C "$root" ls-files '*.csproj' '*.sln' '*.slnx' | head -1)" ]; then
    template=(--template dotnet-api)
  elif [ -f "$root/package.json" ] &&
    jq -e '(.dependencies // {}) + (.devDependencies // {}) | has("react")' "$root/package.json" >/dev/null 2>&1; then
    template=(--template react-web)
  else
    exit 0
  fi

  # Brownfield: existing code gets a template built from its own patterns by
  # the repo-template skill, never the generic one. Hint once per repo.
  sources=$(git -C "$root" ls-files '*.cs' '*.ts' '*.tsx' '*.js' '*.jsx' | wc -l)
  if [ "$sources" -gt "$BROWNFIELD_MIN_SOURCES" ]; then
    marker="${XDG_STATE_HOME:-$HOME/.local/state}/aicode-mcp/hinted/${root//\//%}"
    [ -e "$marker" ] && exit 0
    mkdir -p "$(dirname "$marker")" && touch "$marker"
    emit "aicode-mcp: $(basename "$root") has existing code and no template. To keep its architecture, run /repo-template (pi: /skill:repo-template, copilot: the repo-template skill) to build rules and scaffold methods from its code."
    exit 0
  fi
fi

result=$(cd "$root" && timeout 8 aicode-mcp init --quiet "${template[@]}" 2>/dev/null)
case "$result" in
  *Created* | *Copied*) ;;
  *) exit 0 ;;
esac

emit "aicode-mcp: initialised $(basename "$root") ($(printf '%s' "$result" | tr '\n' ';' | sed 's/;$//; s/;/, /g'))."
exit 0
