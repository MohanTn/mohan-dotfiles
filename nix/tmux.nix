{ config, pkgs, ... }:

{
  # tmux-nerd-font-window-name defaults to showing only the icon; this
  # turns on the "<icon> name" display seen in the target screenshot.
  home.file.".config/tmux/tmux-nerd-font-window-name.yml".text = ''
    show-name: true
  '';

  programs.tmux = {
    enable = true;
    clock24 = true;
    escapeTime = 0;
    historyLimit = 10000;
    keyMode = "vi";
    mouse = true;
    baseIndex = 1;

    # Plugins are pulled from nixpkgs and wired into tmux.conf at build time,
    # so there's no TPM runtime clone step (`prefix + I`) or ~/.tmux/plugins
    # directory living outside the Nix store.
    plugins = with pkgs.tmuxPlugins; [
      sensible
      vim-tmux-navigator
      # Not yet packaged in nixpkgs (as of the pinned release-25.05 input),
      # so it's built directly from upstream instead of bumping the flake
      # input just for one plugin.
      (mkTmuxPlugin {
        pluginName = "tmux-nerd-font-window-name";
        # Upstream's main file keeps its hyphens (unlike most tmux plugins,
        # whose filename swaps them for underscores, which is what
        # mkTmuxPlugin assumes by default).
        rtpFilePath = "tmux-nerd-font-window-name.tmux";
        version = "2025-04-11";
        src = pkgs.fetchFromGitHub {
          owner = "joshmedeski";
          repo = "tmux-nerd-font-window-name";
          rev = "0af812a228e1b9f538b8d220c6c59d82d7228973";
          hash = "sha256-b6CQdN33hU5li/0LUOHMs7oN8ffVRVQlSf17Twhz2e8=";
        };
      })
      {
        plugin = catppuccin;
        extraConfig = ''
          set -g @catppuccin_flavor "mocha"
          # Powerline separators (U+E0B4-E0B7) and the module icons are
          # Private Use Area codepoints. They only align if the *terminal*
          # font is a Nerd Font "Mono" face, whose icons are exactly 1.00
          # cells wide; proportional/Propo fallbacks measure 1.11-1.54 and
          # cannot sit on a cell boundary. Both terminals pin that face
          # declaratively: nix/alacritty.nix and nix/ptyxis.nix. Fix icon
          # rendering there, never by stripping icons out of this file.
          set -g @catppuccin_window_status_style "rounded"
          # Module icons and separators are left at the plugin defaults
          # (catppuccin_options_tmux.conf), which is the styling this theme
          # is designed around.
          # Default window text shows the pane title (#T); switch to the
          # window name (#W) so tmux-nerd-font-window-name's computed
          # icon+name (set via automatic-rename-format) is what's displayed.
          set -g @catppuccin_window_number_position "right"
          set -g @catppuccin_window_text " #W"
          set -g @catppuccin_window_current_text " #W"
        '';
      }
    ];

    extraConfig = ''
      # pi warns on launch when this is off; lets modified Enter (Shift/Ctrl
      # +Enter) reach TUI apps instead of being collapsed to plain Enter.
      # WSL's terminal stack (ConPTY underneath, whatever front-end sits on
      # top) doesn't reliably negotiate the CSI-u keyboard protocol tmux
      # emits here: undecoded escape bytes leak into the shell buffer as
      # visible junk ("ghost text") while typing, and Ctrl+C doesn't clear
      # it because the corruption is below zsh, in the terminal/tmux
      # protocol layer. Keep it on for native Linux (where it's needed for
      # pi), skip it under WSL.
      # tmux runs if-shell/run-shell via /bin/sh (dash here), not
      # default-shell, so this must be POSIX sh, not bash/zsh [[ ]] syntax.
      if-shell -b '! uname -r | grep -qi microsoft' 'set -g extended-keys on'
      if-shell -b '! uname -r | grep -qi microsoft' 'set -g extended-keys-format csi-u'
      set -g status-position bottom
      set -g status-left "#{E:@catppuccin_status_session}"
      set -g status-right-length 100
      set -g status-right "#{E:@catppuccin_status_directory}#{E:@catppuccin_status_date_time}"

      # mouse-drag and copy-mode selections otherwise stay in tmux's own
      # buffer and never reach the Wayland clipboard, so Ctrl+Shift+V outside
      # tmux pastes nothing
      bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "wl-copy"
      bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "wl-copy"
      bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "wl-copy"

      # Enter copy mode, select multiple lines with v/V + movement, y to
      # yank (above). Paste is the reverse: default `]` only replays tmux's
      # own paste buffer, missing anything copied outside tmux (browser,
      # another app), so pull the Wayland clipboard in first.
      bind-key ] run-shell "wl-paste --no-newline 2>/dev/null | tmux load-buffer -" \; paste-buffer
    '';
  };
}
