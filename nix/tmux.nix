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
          # "rounded" needs Powerline U+E0B4-E0B7 glyphs, which VTE-based
          # terminals (e.g. the previously-used Ptyxis) render as stray Greek
          # letters (Omega, Phi) even though the font itself has the correct
          # glyph outlines; "basic" avoids those codepoints entirely.
          set -g @catppuccin_window_status_style "basic"
          # status-right modules (directory/session/date_time) default this
          # to the same broken U+E0B6 glyph independently of the window
          # style above; clear it too.
          set -g @catppuccin_status_left_separator ""
          # Nerd Font icons live in the Unicode Private Use Area, which
          # has no defined East Asian Width (it comes back "Ambiguous").
          # Alacritty's unicode-width crate and VTE's (Ptyxis) width
          # tables each guess a cell width for that glyph independently
          # of the font's own advance metrics, and disagree with plain
          # text, so icons render visibly off-center in status modules
          # while ordinary characters in the same padded slot don't.
          # Alacritty has no ambiguous-width override to force this
          # (unlike kitty/foot/wezterm), so drop the icons instead of
          # continuing to chase padding.
          set -g @catppuccin_session_icon ""
          set -g @catppuccin_directory_icon ""
          set -g @catppuccin_date_time_icon ""
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
      # +Enter) reach TUI apps instead of being collapsed to plain Enter
      set -g extended-keys on

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
