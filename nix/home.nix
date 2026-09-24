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
    ./nix-conf.nix
    ./homebrew.nix
    ./maintenance.nix
    # Exactly one of these configures the interactive shell, chosen by
    # customPackages.enableZsh; both pull their shared half from
    # ./shell-common.nix.
    ./zsh.nix
    ./bash.nix
    ./alacritty.nix
    ./ptyxis.nix
    ./git.nix
    ./agents.nix
    ./claude.nix
    ./copilot.nix
    ./pi.nix
    ./little-coder.nix
    ./tmux.nix
    ./nvim.nix
    configPath
  ];

  # `username` comes from $USER, read impurely in flake.nix and threaded in
  # via extraSpecialArgs, so this config works unmodified on any machine or
  # account name. The repo itself still needs to live at ~/REPO/mohan-dotfiles.
  home.username = username;
  home.homeDirectory = "/home/${username}";

  # Do not change after the first activation.
  home.stateVersion = "25.05";

  # Provides the `home-manager` command itself after the first switch.
  programs.home-manager.enable = true;

  # Ubuntu/WSL (non-NixOS) integration: session vars, locale archive, XDG.
  targets.genericLinux.enable = true;

  # dconf activation needs a live D-Bus user session. Headless shells,
  # containers, and restricted WSL sessions may expose neither the session bus
  # nor its runtime directory, so skip dconf rather than failing the switch.
  dconf.enable = lib.mkDefault (
    builtins.getEnv "DBUS_SESSION_BUS_ADDRESS" != ""
    && builtins.getEnv "XDG_RUNTIME_DIR" != ""
    && builtins.pathExists (builtins.getEnv "XDG_RUNTIME_DIR")
  );

  home.sessionPath = [
    "$HOME/.npm-global/bin"
    "$HOME/.local/bin"
    "$HOME/.local/share/pnpm"
  ];
}