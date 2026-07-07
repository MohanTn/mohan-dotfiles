{ ... }:

{
  # Copilot CLI owns ~/.copilot itself: config.json, mcp-config.json, and
  # session data are runtime state it writes, so the directory is never
  # linked as a whole (same policy as ~/.claude in claude.nix). Only the
  # hooks subtree is served read-only from the store; Copilot loads every
  # *.json in ~/.copilot/hooks as a user-level hook configuration, and
  # mohan-hooks.json points at the scripts next to it.
  #
  # The Copilot CLI binary itself is installed by optional-packages.nix
  # (enableGitHubCopilot), intentionally unpinned like the other npm CLIs.
  home.file.".copilot/hooks".source = ../copilot/hooks;
}
