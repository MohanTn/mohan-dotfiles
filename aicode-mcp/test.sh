#!/usr/bin/env bash
# Tests for aicode-mcp.sh against a throwaway HOME, a stub claude and a stub
# dotnet, cloning a local git repo instead of GitHub. Needs bash, git, jq.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/aicode-mcp.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME/.copilot" "$HOME/.pi/agent" "$work/bin"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
git config --global user.email t@t && git config --global user.name t

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# Absolute shebang: the nix build sandbox has no /usr/bin/env.
shebang="#!$(command -v bash)"
# Stub claude: records every call.
{ echo "$shebang"; cat << 'EOF'; } > "$work/bin/claude"
echo "$*" >> "$HOME/claude.log"
EOF
# Stub dotnet: counts publishes, writes the dll into the -o folder.
{ echo "$shebang"; cat << 'EOF'; } > "$work/bin/dotnet"
echo publish >> "$HOME/dotnet.log"
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { mkdir -p "$2"; touch "$2/aicode-mcp.dll"; }; shift; done
EOF
chmod +x "$work/bin/claude" "$work/bin/dotnet"
export CLAUDE_BIN="$work/bin/claude" DOTNET="$work/bin/dotnet"
export AICODE_MCP_DIR="$HOME/.local/share/aicode-mcp-dotnet"

# Upstream repo to clone from.
git init -q "$work/upstream"
git -C "$work/upstream" commit -q --allow-empty -m one
export AICODE_MCP_REPO="$work/upstream"

# A user-added server must survive register and unregister.
echo '{"mcpServers":{"mine":{"command":"x"}}}' > "$HOME/.copilot/mcp-config.json"

bash "$script" install > /dev/null
[ -f "$AICODE_MCP_DIR/.publish/aicode-mcp.dll" ] || fail "install did not publish"
[ "$(wc -l < "$HOME/dotnet.log")" -eq 1 ] || fail "expected one publish"
pass "install clones and publishes"

bash "$script" install > /dev/null
[ "$(wc -l < "$HOME/dotnet.log")" -eq 1 ] || fail "republished an unchanged HEAD"
pass "unchanged HEAD skips the rebuild"

git -C "$work/upstream" commit -q --allow-empty -m two
bash "$script" install > /dev/null
[ "$(git -C "$AICODE_MCP_DIR" rev-parse HEAD)" = "$(git -C "$work/upstream" rev-parse HEAD)" ] || fail "did not pull"
[ "$(wc -l < "$HOME/dotnet.log")" -eq 2 ] || fail "new HEAD was not rebuilt"
pass "new upstream commit is pulled and rebuilt"

c="$HOME/.copilot/mcp-config.json" p="$HOME/.pi/agent/mcp.json"
jq -e '.mcpServers.mine.command == "x"' "$c" > /dev/null || fail "copilot user server lost"
jq -e '.mcpServers["scaffold-mcp"].args == ["mcp-serve","--server","scaffold"] and .mcpServers["architect-mcp"].type == "local"' "$c" > /dev/null \
  || fail "copilot entries wrong"
jq -e '.mcpServers["architect-mcp"].command == "aicode-mcp" and .mcpServers["scaffold-mcp"].args[2] == "scaffold"' "$p" > /dev/null \
  || fail "pi entries wrong"
rg -q -- "mcp add --scope user scaffold-mcp -- aicode-mcp mcp-serve --server scaffold" "$HOME/claude.log" || fail "claude scaffold not added"
rg -q -- "mcp add --scope user architect-mcp -- aicode-mcp mcp-serve --server architect" "$HOME/claude.log" || fail "claude architect not added"
[ -e "$AICODE_MCP_DIR/.registered" ] || fail "no .registered marker"
pass "registered in claude, copilot and pi"

: > "$HOME/claude.log"
bash "$script" unregister > /dev/null
jq -e '.mcpServers | has("scaffold-mcp") or has("architect-mcp") | not' "$c" > /dev/null || fail "copilot entries left"
jq -e '.mcpServers.mine.command == "x"' "$c" > /dev/null || fail "copilot user server removed"
jq -e '.mcpServers == {}' "$p" > /dev/null || fail "pi entries left"
rg -q -- "mcp remove --scope user architect-mcp" "$HOME/claude.log" || fail "claude not unregistered"
[ ! -e "$AICODE_MCP_DIR/.registered" ] || fail ".registered marker left"
pass "unregister removes only aicode entries"

echo "all aicode-mcp tests passed"
