{ ... }:

{
  # Ptyxis itself is the system apt package (see genericLinux.enable in
  # home.nix); only its dconf preferences are managed here. Glyph install is
  # in packages.nix (nerd-fonts.jetbrains-mono); the "Mono" face keeps
  # Powerline/icon glyphs single-width in the terminal grid.
  dconf.settings."org/gnome/Ptyxis" = {
    use-system-font = false;
    font-name = "JetBrainsMono Nerd Font Mono 12";
  };
}
