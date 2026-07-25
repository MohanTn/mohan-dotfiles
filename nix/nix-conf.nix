{ config, ... }:

{
  # Permanent fix for `error: experimental Nix feature 'nix-command' is
  # disabled` (and its `flakes` twin). Everything in this repo — `nix flake
  # check`, `nix run`, `home-manager switch --flake` — needs both features,
  # and a Nix that came from a distro package, an older single-user install,
  # or a company image enables neither. Owning ~/.config/nix/nix.conf turns
  # them on once, per user, for every shell and every tool that shells out to
  # nix, instead of relying on each caller to pass flags.
  #
  # `extra-experimental-features`, not `experimental-features`: the extra-
  # form appends to whatever /etc/nix/nix.conf already enables. Assigning the
  # plain key would replace the system list, silently dropping features the
  # machine's installer turned on (the Determinate installer enables more
  # than these two).
  #
  # This file is a read-only store symlink, so machine-local Nix settings
  # (substituters, access-tokens, trusted keys — often secret) do not belong
  # here. Put them in ~/.config/nix/nix.conf.local: the trailing `!include`
  # reads that file when it exists and stays quiet when it does not.
  #
  # setup.sh covers the window before the first activation by exporting the
  # same features via NIX_CONFIG for its own run.
  home.file.".config/nix/nix.conf".text = ''
    # Managed by mohan-dotfiles (nix/nix-conf.nix) — edits here are reverted.
    extra-experimental-features = nix-command flakes
    !include ${config.home.homeDirectory}/.config/nix/nix.conf.local
  '';
}
