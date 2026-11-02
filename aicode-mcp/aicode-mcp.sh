#!/usr/bin/env bash
# aicode-mcp.sh: install and register the aicode-mcp MCP servers
# (github.com/MohanTn/aicode-mcp-dotnet) for Claude Code, Copilot CLI and Pi.
#
#   aicode-mcp.sh install      clone or fast-forward the repo, publish it when
#                              HEAD moved, then register
#   aicode-mcp.sh register     add scaffold-mcp and architect-mcp to every harness
#                              and the scaffold/architect hooks to Claude Code
#   aicode-mcp.sh unregister   remove them again (the enableAicodeMcp=false path)
#
# The servers speak MCP over stdio only, so nothing is started here: each
# harness spawns `aicode-mcp mcp-serve --server <name>` per session. The
# `aicode-mcp` command itself is the wrapper nix/aicode-mcp.nix puts on PATH.
#
# Env: AICODE_MCP_DIR (checkout, default ~/.local/share/aicode-mcp-dotnet),
# AICODE_MCP_REPO (clone URL), DOTNET (dotnet binary, install only),
# CLAUDE_BIN (claude binary, default: found on PATH or ~/.local/bin).
set -euo pipefail

AICODE_MCP_DIR="${AICODE_MCP_DIR:-$HOME/.local/share/aicode-mcp-dotnet}"
AICODE_MCP_REPO="${AICODE_MCP_REPO:-https://github.com/MohanTn/aicode-mcp-dotnet}"
SERVERS=(scaffold architect)

claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ]; then echo "$CLAUDE_BIN"
  elif command -v claude > /dev/null 2>&1; then command -v claude
  elif [ -x "$HOME/.local/bin/claude" ]; then echo "$HOME/.local/bin/claude"
  fi
}

# Upsert ($2 = jq object) or delete ($2 empty) the aicode entries in an
# mcpServers JSON file, leaving every other server untouched.
edit_json() {
  local file="$1" entries="$2" tmp
  if [ -z "$entries" ] && [ ! -f "$file" ]; then return 0; fi
  mkdir -p "$(dirname "$file")"
  [ -s "$file" ] || echo '{}' > "$file"
  tmp="$(mktemp)"
  if [ -n "$entries" ]; then
    jq --argjson e "$entries" '.mcpServers = ((.mcpServers // {}) + $e)' "$file" > "$tmp"
  else
    jq 'if .mcpServers then .mcpServers |= del(.["scaffold-mcp"], .["architect-mcp"]) else . end' "$file" > "$tmp"
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Claude Code hooks (README "Hooks"): scaffold gates the first Write of a new
# file, architect feeds RULES.yaml back after edits. Both are no-ops in a
# project without a sourceTemplate and fail open, so they are safe globally.
# Entries are recognised by their command so re-running never duplicates them
# and unregister removes only ours. $1 = add|remove.
claude_hooks() {
  local file="$HOME/.claude/settings.json" tmp
  if [ "$1" = remove ] && [ ! -f "$file" ]; then return 0; fi
  mkdir -p "$(dirname "$file")"
  [ -s "$file" ] || echo '{}' > "$file"
  tmp="$(mktemp)"
  jq --arg op "$1" '
    def ours: ([.hooks[]?.command] | any(test("aicode-mcp hook")));
    def strip(ev): .hooks[ev] = ((.hooks[ev] // []) | map(select(ours | not)));
    strip("PreToolUse") | strip("PostToolUse")
    | if $op == "add" then
        .hooks.PreToolUse += [{matcher: "Write", hooks: [{type: "command", command: "aicode-mcp hook --type scaffold"}]}]
        | .hooks.PostToolUse += [{matcher: "Edit|Write|MultiEdit", hooks: [{type: "command", command: "aicode-mcp hook --type architect"}]}]
      else . end
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

register() {
  local s claude copilot='{}' pi='{}'
  claude="$(claude_bin)"
  for s in "${SERVERS[@]}"; do
    if [ -n "$claude" ]; then
      "$claude" mcp remove --scope user "$s-mcp" > /dev/null 2>&1 || true
      "$claude" mcp add --scope user "$s-mcp" -- aicode-mcp mcp-serve --server "$s" > /dev/null
    fi
    copilot="$(jq --arg n "$s-mcp" --arg s "$s" \
      '.[$n] = {type: "local", command: "aicode-mcp", args: ["mcp-serve", "--server", $s], tools: ["*"]}' <<< "$copilot")"
    pi="$(jq --arg n "$s-mcp" --arg s "$s" \
      '.[$n] = {command: "aicode-mcp", args: ["mcp-serve", "--server", $s], description: ("aicode-mcp " + $s + " tools for .NET and React projects")}' <<< "$pi")"
  done
  [ -n "$claude" ] || echo "aicode-mcp: claude not installed, skipped its registration" >&2
  edit_json "$HOME/.copilot/mcp-config.json" "$copilot"
  edit_json "$HOME/.pi/agent/mcp.json" "$pi"
  claude_hooks add
  # Marker for nix/aicode-mcp.nix: only unregister on a disabled switch when
  # something was registered, instead of calling claude on every machine.
  mkdir -p "$AICODE_MCP_DIR" && touch "$AICODE_MCP_DIR/.registered"
  echo "aicode-mcp: registered ${SERVERS[*]} for claude, copilot and pi"
}

unregister() {
  local s claude
  claude="$(claude_bin)"
  if [ -n "$claude" ]; then
    for s in "${SERVERS[@]}"; do
      "$claude" mcp remove --scope user "$s-mcp" > /dev/null 2>&1 || true
    done
  fi
  edit_json "$HOME/.copilot/mcp-config.json" ""
  edit_json "$HOME/.pi/agent/mcp.json" ""
  claude_hooks remove
  rm -f "$AICODE_MCP_DIR/.registered"
  echo "aicode-mcp: unregistered from claude, copilot and pi"
}

install() {
  : "${DOTNET:?DOTNET must point at a .NET 10 SDK dotnet binary}"
  if [ -d "$AICODE_MCP_DIR/.git" ]; then
    git -C "$AICODE_MCP_DIR" pull --ff-only --quiet \
      || echo "aicode-mcp: pull failed (local changes or offline), keeping the current checkout" >&2
  else
    git clone --quiet "$AICODE_MCP_REPO" "$AICODE_MCP_DIR"
  fi

  local head out="$AICODE_MCP_DIR/.publish"
  head="$(git -C "$AICODE_MCP_DIR" rev-parse HEAD)"
  if [ "$(cat "$out/.commit" 2> /dev/null)" != "$head" ]; then
    echo "aicode-mcp: building ${head:0:7}"
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" publish \
      "$AICODE_MCP_DIR/src/Aicode.Mcp.Cli" -c Release -o "$out" --nologo -v quiet > /dev/null
    echo "$head" > "$out/.commit"
  fi
  register
}

case "${1:-}" in
  install) install ;;
  register) register ;;
  unregister) unregister ;;
  *) echo "usage: $0 install|register|unregister" >&2; exit 2 ;;
esac
