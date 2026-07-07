{ username, lib, ... }:

let
  userPackagesConfig = /home/${username}/.config/mohan-dotfiles/packages-config.nix;
  configPath = if builtins.pathExists userPackagesConfig
               then userPackagesConfig
               else ./default-packages-config.nix;
in
{
  imports = [
    ./packages.nix
    ./optional-packages.nix
    ./maintenance.nix
    ./zsh.nix
    ./git.nix
    ./claude.nix
    ./copilot.nix
    ./nvim.nix
    ./pi.nix
    configPath
  ];

  # `username` comes from $USER, read impurely in flake.nix and threaded in
  # via extraSpecialArgs, so this config works unmodified on any machine or
  # account name. The repo itself still needs to live at
  # ~/REPO/mohan-dotfiles (see nvim.nix).
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
