{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.customPackages;
in
{
  options.customPackages = {
    enableDocker = mkEnableOption "Docker and Docker Compose";
    enablePython = mkEnableOption "Python dev tools";
    enableGitHubCopilot = mkEnableOption "GitHub Copilot CLI installer";
    enablePipelineWorker = mkEnableOption "Pipeline Worker npm package";
    enableLocalScribe = mkEnableOption "LocalScribe (from GitHub releases)";
    enableGitConfig = mkEnableOption "Git configuration (userName and userEmail)";
    enableGcloud = mkEnableOption "Google Cloud SDK (gcloud)";
    enableAicodeMcp = mkEnableOption "aicode-mcp scaffold/architect MCP servers for Claude, Copilot and Pi (nix/aicode-mcp.nix)";

    # These two are opt-*out*, unlike everything above: they describe the
    # terminal this repo is built around, so a config file that predates them
    # (or the packaged default) keeps the behaviour it already had.
    enableZsh = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Use zsh as the interactive shell (nix/zsh.nix: oh-my-posh prompt,
        zinit plugin stack). When false, nix/bash.nix configures bash with
        the same aliases, helpers and environment instead, minus the prompt
        and plugin stack, which have no bash counterpart.
      '';
    };

    enableTmux = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install and configure tmux (nix/tmux.nix). When false, neither the
        tmux config nor the auto-start block in the shell rc is generated.
      '';
    };

    tmuxAutostart = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Auto-start a tmux session in each new interactive terminal. Only has
        an effect when enableTmux is true. Off by default, so terminals open
        a plain shell and you attach with `tmux` / `tmux attach` yourself.
      '';
    };
  };

  config.home.packages = with pkgs;
    (optionals cfg.enablePython [
      python3
      poetry
      python3Packages.pip-tools
    ])
    ++ (optionals cfg.enableDocker [
      docker
      docker-compose
    ])
    ++ (optionals cfg.enableGcloud [
      # `gcloud components install` can't write into the read-only Nix
      # store, so extra components (e.g. gke-gcloud-auth-plugin for
      # kubectl<->GKE auth) must be added here instead and rebuilt via
      # ./setup.sh when a new one is needed.
      (google-cloud-sdk.withExtraComponents [
        google-cloud-sdk.components.gke-gcloud-auth-plugin
        google-cloud-sdk.components.kubectl
      ])
    ]);

  config.programs.git = mkIf cfg.enableGitConfig {
    enable = true;
    userName = "MohanTn";
    userEmail = "mohan.tn100@gmail.com";
  };

  config.home.activation = {
    installPipelineWorker = mkIf cfg.enablePipelineWorker (hm.dag.entryAfter [ "installPackages" ] ''
      export PATH="${pkgs.nodejs_24}/bin:$PATH"
      export NPM_CONFIG_PREFIX="$HOME/.npm-global"

      $DRY_RUN_CMD mkdir -p "$NPM_CONFIG_PREFIX"
      echo "Installing pipeline-worker..."
      ($DRY_RUN_CMD npm install --global --no-save pipeline-worker) || echo "Warning: pipeline-worker installation failed, continuing" >&2
    '');

    installCopilot = mkIf cfg.enableGitHubCopilot (hm.dag.entryAfter [ "installPackages" ] ''
      export PATH="${pkgs.nodejs_24}/bin:$PATH"
      export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      echo "Installing GitHub Copilot CLI via npm..."
      ($DRY_RUN_CMD npm install -g @github/copilot) || echo "Warning: GitHub Copilot CLI installation failed, continuing" >&2
    '');

    installLocalScribe = mkIf cfg.enableLocalScribe (hm.dag.entryAfter [ "installPackages" ] ''
      export PATH="${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.bash}/bin:$PATH"

      (
        INSTALL_DIR="$HOME/.local/bin"
        mkdir -p "$INSTALL_DIR"

        echo "Installing LocalScribe from GitHub releases..."

        # Fetch latest release info
        RELEASE_DATA=$(curl -fsSL https://api.github.com/repos/MohanTn/LocalScribe/releases/latest)

        # Find Linux asset (looking for .tar.gz, .zip, or binary)
        LINUX_ASSET=$(echo "$RELEASE_DATA" | jq -r '.assets[] | select(.name | test("linux|Linux|x86_64")) | .browser_download_url' | head -1)

        if [ -z "$LINUX_ASSET" ]; then
          echo "Error: Could not find Linux asset in latest release" >&2
          exit 1
        fi

        echo "Downloading: $LINUX_ASSET"
        $DRY_RUN_CMD curl -fsSL -o "$INSTALL_DIR/localscribe" "$LINUX_ASSET"
        $DRY_RUN_CMD chmod +x "$INSTALL_DIR/localscribe"
        echo "✓ LocalScribe installed to $INSTALL_DIR/localscribe"
      ) || echo "Warning: LocalScribe installation failed, continuing" >&2
    '');
  };
}
