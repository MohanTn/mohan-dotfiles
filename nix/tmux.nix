{ ... }:

{
  # tmux/tmux.conf stays the single source of truth; the Home Manager tmux
  # module is deliberately not used so the file reads the same everywhere.
  home.file.".tmux.conf".source = ../tmux/tmux.conf;
}
