{ config, lib, pkgs, ... }:

{
  # Copilot CLI hooks: the personal hook suite (Copilot ports of the Claude
  # hooks in claude/hooks, reusing those scripts via payload translation) plus
  # ~/.copilot/hooks/ recursively (verified 1.0.70; the docs claim top-level
  # only), so the adapter checkout must live outside that directory or its
  # package.json is rejected as an invalid hook config on every session start.
  # The rest of ~/.copilot (settings.json, session state) stays unmanaged
  # because Copilot writes to it at runtime.
  home.file.".copilot/hooks".source = ../copilot/hooks;

  # Copilot CLI has no @-import directive (unlike claude/CLAUDE.md's
  # `@~/.agents/AGENTS.md`), so the global instructions are generated at
  # eval time from the same source instead of hand-duplicated: this reads
  # agents/AGENTS.md into the store file's content, so agents/AGENTS.md
  # stays the single authored system prompt and copilot-instructions.md is
  # never edited directly.
  home.file.".copilot/copilot-instructions.md".text =
    builtins.readFile ../agents/AGENTS.md;

  # The scaffold MCP server (agents/boilerplats) has been removed; deregister
  # any stale entry a prior switch left in ~/.copilot/mcp-config.json, leaving
  # any user-added servers untouched.
  home.activation.removeCopilotScaffoldMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.nodejs}/bin/node -e '
      const fs = require("fs");
      const p = process.env.HOME + "/.copilot/mcp-config.json";
      let cfg = {};
      try { cfg = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
      if (cfg.mcpServers && cfg.mcpServers.scaffold) {
        delete cfg.mcpServers.scaffold;
        fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
      }
    '
  '';
}
