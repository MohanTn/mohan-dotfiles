{ ... }:

{
  imports = [
    ./packages.nix
    ./zsh.nix
    ./git.nix
    ./claude.nix
    ./tmux.nix
    ./nvim.nix
    ./pi.nix
  ];

  # The whole setup assumes this user and the repo checked out at
  # ~/REPO/claude-code-helpers (see nvim.nix). On a fresh WSL distro,
  # create the user as "mohan" during setup.
  home.username = "mohan";
  home.homeDirectory = "/home/mohan";

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
