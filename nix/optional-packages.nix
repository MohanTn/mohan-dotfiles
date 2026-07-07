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
    enableHerdr = mkEnableOption "Herdr installer";
    enablePipelineWorker = mkEnableOption "Pipeline Worker npm package";
    enableLocalScribe = mkEnableOption "LocalScribe (from GitHub releases)";
    enableGitConfig = mkEnableOption "Git configuration (userName and userEmail)";
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
    ]);

  config.programs.git = mkIf cfg.enableGitConfig {
    enable = true;
    userName = "MohanTn";
    userEmail = "mohan.tn100@gmail.com";
  };

  config.home.activation = {
    installPipelineWorker = mkIf cfg.enablePipelineWorker (hm.dag.entryAfter [ "installPackages" ] ''
      PATH="${pkgs.nodejs_22}/bin:$PATH"
      NPM_CONFIG_PREFIX="$HOME/.npm-global"

      $DRY_RUN_CMD mkdir -p "$NPM_CONFIG_PREFIX"
      echo "Installing pipeline-worker..."
      $DRY_RUN_CMD npm install --global --no-save pipeline-worker
    '');

    installHerdr = mkIf cfg.enableHerdr (hm.dag.entryAfter [ "installPackages" ] ''
      export PATH="${pkgs.curl}/bin:$PATH"
      echo "Installing herdr from https://herdr.dev/install.sh"
      ($DRY_RUN_CMD curl -fsSL https://herdr.dev/install.sh | $DRY_RUN_CMD sh) || echo "Warning: herdr installation failed, continuing" >&2
    '');

    installCopilot = mkIf cfg.enableGitHubCopilot (hm.dag.entryAfter [ "installPackages" ] ''
      export PATH="${pkgs.curl}/bin:${pkgs.bash}/bin:$PATH"
      echo "Installing GitHub Copilot CLI from https://gh.io/copilot-install"
      ($DRY_RUN_CMD curl -fsSL https://gh.io/copilot-install | $DRY_RUN_CMD bash) || echo "Warning: GitHub Copilot CLI installation failed, continuing" >&2
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
