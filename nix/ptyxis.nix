{ ... }:

{
  # Ptyxis is the terminal actually in use on this machine (Alacritty needs
  # nixGL to launch), so its font has to be pinned here or nothing else in
  # the stack can render Nerd Font glyphs correctly.
  #
  # Left on the default `use-system-font = true` ("Monospace"), fontconfig
  # resolves body text to DejaVu Sans Mono, which has NO Private Use Area
  # coverage at all. Every icon and Powerline separator is therefore drawn
  # by whichever font Pango happens to substitute per-glyph, and the
  # installed candidates are not interchangeable. Measured advance widths,
  # in cells (glyph advance / 'M' advance, upem-normalised):
  #
  #   face                              U+E0B6  U+E795  U+F07B  U+F01F0
  #   JetBrainsMono Nerd Font Mono        1.00    1.00    1.00    1.00
  #   JetBrainsMonoNL Nerd Font           1.00    1.00    1.00    1.00
  #   JetBrainsMonoNL Nerd Font Propo     1.00    1.17    1.54    1.39
  #
  # The Propo (proportional) faces are installed and reachable by
  # substitution, and their fractional advances cannot land on a cell
  # boundary, which is what made status icons sit visibly off-center while
  # plain text in the same padded slot did not. Adwaita Sans also covers
  # U+E0B4 and is proportional too.
  #
  # Note this is NOT the East Asian "Ambiguous" width issue an earlier pass
  # blamed: the Ptyxis profile already defaults to cjk-ambiguous-width
  # 'narrow', so VTE budgets one cell, correctly. The mismatch was purely
  # which font supplied the glyph.
  #
  # Pinning the "Mono" face makes every PUA glyph come from one font at
  # exactly 1.00 cells, so no substitution happens and nothing is
  # fractional. Fix icon rendering here, not by deleting icons downstream.
  dconf.settings."org/gnome/Ptyxis" = {
    use-system-font = false;
    font-name = "JetBrainsMono Nerd Font Mono 10";
  };
}
