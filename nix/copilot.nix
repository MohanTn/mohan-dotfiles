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

  # Scaffold MCP server for Copilot CLI: ~/.copilot/mcp-config.json is
  # runtime-writable (Copilot's /mcp command edits it), so like settings.json
  # it can't be a store symlink — the scaffold entry is merged in only when
  # missing, leaving any user-added servers untouched. node (not bash+jq) does
  # the merge to keep quoting sane inside this activation snippet.
  home.activation.copilotScaffoldMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.nodejs}/bin/node -e '
      const fs = require("fs");
      const dir = process.env.HOME + "/.copilot";
      const p = dir + "/mcp-config.json";
      let cfg = {};
      try { cfg = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
      cfg.mcpServers = cfg.mcpServers || {};
      if (!cfg.mcpServers.scaffold) {
        cfg.mcpServers.scaffold = {
          type: "local",
          command: "node",
          args: [process.env.HOME + "/.agents/boilerplats/mcp-server.js"],
          tools: ["*"],
        };
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
      }
    '
  '';
}
