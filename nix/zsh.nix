{ config, ... }:

{
  programs.zsh = {
    enable = true;

    oh-my-zsh = {
      enable = true;
      # Prompt itself comes from zsh/prompt.zsh below, not an oh-my-zsh theme.
      theme = "";
      plugins = [ "git" ];
      extraConfig = ''
        ENABLE_CORRECTION="true"
      '';
    };

    shellAliases = {
      cc = "claude --dangerously-skip-permissions";
      repo = "cd $HOME/REPO";
      sl = "$HOME/REPO/quality-worker/sonar_lite.py";
    };

    initContent = ''
      # nvim as editor (plain vim over SSH)
      if [[ -n $SSH_CONNECTION ]]; then
        export EDITOR='vim'
      else
        export EDITOR='nvim'
      fi

      # Legacy per-machine installs, kept working where they exist.
      # Fresh machines get dotnet and node from Nix instead.
      if [ -d "$HOME/.dotnet" ]; then
        export DOTNET_ROOT="$HOME/.dotnet"
        export PATH="$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools"
      fi
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

      # Default `ls` directory blue (di=01;34) is too dark to read on a dark
      # background; override to a brighter cyan, keep everything else default.
      command -v dircolors >/dev/null 2>&1 && eval "$(dircolors -b)"
      export LS_COLORS="''${LS_COLORS}:di=01;36"

      source ${../zsh/prompt.zsh}

      # Machine-local secrets and overrides, never committed.
      # PIPELINE_WORKER_GITHUB_TOKEN and similar live here.
      [ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
    '';
  };

  # fuzzy history (ctrl-r) and file search (ctrl-t), wired into zsh
  programs.fzf.enable = true;

  home.sessionVariables = {
    LANG = "en_US.UTF-8";
    # npm global installs go to a user-writable prefix (the Nix store is
    # read-only); ~/.npm-global/bin is on home.sessionPath.
    NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
    # pnpm's global bin dir (pnpm link --global, pnpm add -g); the Nix store
    # pnpm binary can't write there itself, so it's declared here instead of
    # via `pnpm setup`. ~/.local/share/pnpm is on home.sessionPath.
    PNPM_HOME = "${config.home.homeDirectory}/.local/share/pnpm";
    FREEBUFF_MODE = "true";
    PIPELINE_WORKER_AGENT = "claude";
    PIPELINE_WORKER_FORGE = "github";
    PIPELINE_WORKER_INTENT_MODEL = "haiku";
    PIPELINE_WORKER_CLEANUP = "true";
    PIPELINE_WORKER_POLL_INTERVAL_SECONDS = "15";
    PIPELINE_WORKER_CLEANUP_EARLY = "true";
    PIPELINE_WORKER_UPDATE_CHANGELOG = "true";
    # PIPELINE_WORKER_GITHUB_TOKEN is a secret: set it in ~/.zshrc.local
  };
}
