{ username, ... }:

{
  imports = [
    ./packages.nix
    ./zsh.nix
    ./git.nix
    ./claude.nix
    ./nvim.nix
    ./pi.nix
  ];

  # `username` comes from $USER, read impurely in flake.nix and threaded in
  # via extraSpecialArgs, so this config works unmodified on any machine or
  # account name. The repo itself still needs to live at
  # ~/REPO/claude-code-helpers (see nvim.nix).
  home.username = username;
  home.homeDirectory = "/home/${username}";

  # Do not change after the first activation.
  home.stateVersion = "25.05";

  # Provides the `home-manager` command itself after the first switch.
  programs.home-manager.enable = true;

  # Ubuntu/WSL (non-NixOS) integration: session vars, locale archive, XDG.
  targets.genericLinux.enable = true;

  home.sessionPath = [
    "$HOME/.npm-global/bin"
    "$HOME/.local/bin"
  ];
}
