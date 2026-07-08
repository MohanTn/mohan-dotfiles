{ ... }:

{
  # Copilot CLI owns ~/.copilot itself: config.json, mcp-config.json, and
  # session data are runtime state it writes, so the directory is never
  # linked as a whole (same policy as ~/.claude in claude.nix). Per-entry
  # links only: Copilot loads every *.json in ~/.copilot/hooks as a
  # user-level hook configuration (mohan-hooks.json points at the scripts
  # next to it), copilot-instructions.md as global user instructions,
  # agents/*.agent.md as custom agents, and skills/*/SKILL.md as personal
  # skills. Read-only store links mean in-CLI agent/skill creation to the
  # user location fails; add new ones in this repo instead.
  #
  # The Copilot CLI binary itself is installed by optional-packages.nix
  # (enableGitHubCopilot), intentionally unpinned like the other npm CLIs.
  home.file = {
    ".copilot/hooks".source = ../copilot/hooks;
    ".copilot/copilot-instructions.md".source = ../copilot/copilot-instructions.md;
    ".copilot/agents".source = ../copilot/agents;
    ".copilot/skills".source = ../copilot/skills;
  };
}
