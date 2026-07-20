{ pkgs, ... }:

{
  # lets GTK/Pango apps discover home.packages fonts, including
  # the Nerd Font below that tmux's catppuccin status bar and Claude Code
  # icons depend on
  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    # toolchain the configs in this repo depend on
    ripgrep # Telescope live-grep
    fd # Telescope file finder
    jq # every Claude Code hook
    universal-ctags # session-start.sh's repo map (folder -> file -> symbol)
    python3 # statusline-usage.py
    nodejs_22 # LazyVim LSP extras, pi extensions, npm global CLIs
    pnpm # for enriched_planning
    gcc # Treesitter parser builds
    gnumake
    curl
    oh-my-posh # zsh prompt, catppuccin_mocha theme (nix/zsh.nix)
    bubblewrap # Claude Code's Bash sandbox (claude/settings.json sandbox.enabled)
    socat # network relay the Claude Code sandbox proxy depends on

    # Nerd Font glyphs for tmux (catppuccin status bar) and terminal icons.
    # symbols-only is a dedicated icon fallback: some Powerline glyphs
    # (e.g. U+E0B6) render incorrectly straight out of the patched
    # jetbrains-mono build on this system, so the terminal font is set to
    # fall back to this font (see nix/README or alacritty.nix font.normal.family).
    nerd-fonts.jetbrains-mono
    nerd-fonts.symbols-only

    # dev platforms
    dotnet-sdk_8

    # GitHub
    gh

    # quality of life on any Linux box or fresh WSL image
    wl-clipboard # bridges tmux copy-mode selections to the system clipboard
    bat
    tree
    htop
    wget
    unzip
    lazygit
    wslu # wslview and friends; harmless on plain Linux

    # AI custom assisted packages
    # pipeline-worker or pw, local-scribe (TODO: define these custom packages)
  ];
}
