{ pkgs, ... }:

{
  # Systemd user timer to auto-update and clean tools daily
  systemd.user.services.tools-maintenance = {
    Unit = {
      Description = "Update and clean npm packages and tools";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "tools-maintenance" ''
        set -e
        export PATH="${pkgs.nodejs_22}/bin:${pkgs.curl}/bin:$PATH"
        export NPM_CONFIG_PREFIX="$HOME/.npm-global"

        echo "[$(date)] Starting tools maintenance..."

        # Update npm itself
        echo "Updating npm..."
        npm install --global npm@latest 2>/dev/null || true

        # Update global npm packages
        echo "Updating global npm packages..."
        npm update --global 2>/dev/null || true

        # Clean npm cache
        echo "Cleaning npm cache..."
        npm cache clean --force 2>/dev/null || true

        # Prune old npm packages
        echo "Pruning unused npm dependencies..."
        npm prune --global 2>/dev/null || true

        echo "[$(date)] Tools maintenance completed successfully"
      ''}";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.user.timers.tools-maintenance = {
    Unit = {
      Description = "Daily tools maintenance timer";
      Requires = [ "tools-maintenance.service" ];
    };

    Timer = {
      # Run daily at 2 AM
      OnCalendar = "*-*-* 02:00:00";
      Persistent = true;
      AccuracySec = "1h";
    };

    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
