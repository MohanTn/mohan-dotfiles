{ pkgs, ... }:

{
  home.packages = with pkgs; [
    # toolchain the configs in this repo depend on
    neovim
    ripgrep # Telescope live-grep
    fd # Telescope file finder
    jq # every Claude Code hook
    python3 # statusline-usage.py
    nodejs_22 # LazyVim LSP extras, pi extensions, npm global CLIs
    gcc # Treesitter parser builds
    gnumake
    curl

    # dev platforms
    dotnet-sdk_8

    # GUI editor (replaces VS Code; needs WSLg on WSL)
    zed-editor

    # GitHub
    gh

    # quality of life on any Linux box or fresh WSL image
    bat
    tree
    htop
    wget
    unzip
    lazygit
    wslu # wslview and friends; harmless on plain Linux
  ];
}
