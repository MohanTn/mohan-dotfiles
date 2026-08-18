{ pkgs, lib, config, ... }:

{
  home.file = {
    ".claude/CLAUDE.md".source = ../claude/CLAUDE.md;
    ".claude/statusline-usage.py".source = ../claude/statusline-usage.py;
    ".claude/session-analytics.py".source = ../claude/session-analytics.py;
    # session-analytics.py loads this from next to itself for its web UI.
    ".claude/session-web.py".source = ../claude/session-web.py;
    ".claude/bash-allowlist".source = ../claude/bash-allowlist;
    ".claude/hooks".source = ../claude/hooks;
    ".claude/skills".source = ../agents/skills;
  };

  # settings.json is the one config file Claude Code itself edits at runtime
  # (permission grants, /config), so it is deployed as a writable copy that
  # each switch refreshes from the repo. If the live file drifted since the
  # last switch, the previous version is kept next to it for diffing.
  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    claudeDir="$HOME/.claude"
    src=${../claude/settings.json}
    dst="$claudeDir/settings.json"
    run mkdir -p "$claudeDir"
    if [ -f "$dst" ] && [ ! -L "$dst" ] && ! cmp -s "$src" "$dst"; then
      run cp "$dst" "$dst.hm-prev"
    fi
    # a legacy install.sh symlink must go first, or install would write
    # through it into the repo checkout
    if [ -L "$dst" ]; then
      run rm "$dst"
    fi
    run install -m 0644 "$src" "$dst"
  '';

  # Claude Code itself stays on the official native installer so it keeps
  # self-updating; only bootstrap it when missing.
  home.activation.installClaude = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -x "$HOME/.local/bin/claude" ] && ! command -v claude >/dev/null 2>&1; then
      run ${pkgs.bash}/bin/bash -c '${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash'
    fi
  '';

  # Scaffold MCP server (agents/boilerplats/mcp-server.js): registered at user
  # scope so every project gets the scaffold_* tools. Claude Code keeps
  # user-scope MCP servers in ~/.claude.json, which it rewrites at runtime, so
  # this goes through `claude mcp add` (idempotent via the `mcp get` probe)
  # instead of a home.file entry. Deps land in ~/.cache/boilerplats via
  # agents.nix's boilerplatsDeps, which mcp-server.js falls back to.
  home.activation.scaffoldMcp = lib.hm.dag.entryAfter [ "installClaude" ] ''
    claudeBin="$HOME/.local/bin/claude"
    command -v claude >/dev/null 2>&1 && claudeBin="$(command -v claude)"
    if [ -x "$claudeBin" ] && ! "$claudeBin" mcp get scaffold >/dev/null 2>&1; then
      run "$claudeBin" mcp add --scope user scaffold -- ${pkgs.nodejs}/bin/node "$HOME/.agents/boilerplats/mcp-server.js" || true
    fi
  '';
}
