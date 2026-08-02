{ pkgs, lib, ... }:

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

    # GitHub & GitLab
    gh    # GitHub CLI
    glab  # GitLab CLI

    # quality of life on any Linux box or fresh WSL image
    wl-clipboard # bridges tmux copy-mode selections to the system clipboard
    bat
    tree
    htop
    wget
    unzip
    wslu # wslview and friends; harmless on plain Linux
    tealdeer # `tldr`: community example-driven cheatsheets over man pages
    eza # `ls` alias below: adds a headered table layout to -la (nix/zsh.nix)
    tidy-viewer # renders delimited text as a bordered table, used by the
                # docker ps/ollama ps wrappers in zsh/table-view.zsh

    # Custom assisted packages installed via setup-packages.sh or optional-packages.nix
    # pipeline-worker, local-scribe
  ];

  # hunkdiff: interactive hunk-by-hunk diff review, used for code review
  home.activation.installHunkdiff = lib.hm.dag.entryAfter [ "installPackages" ] ''
    export PATH="${pkgs.nodejs_22}/bin:$PATH"
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"

    if ! command -v hunkdiff >/dev/null 2>&1; then
      echo "Installing hunkdiff..."
      $DRY_RUN_CMD npm install --global hunkdiff
    fi
  '';
}
