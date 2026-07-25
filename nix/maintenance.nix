{ config, pkgs, ... }:

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

        # Nix store cleanup. Order matters: every Home Manager generation is a
        # GC root, so expiring them first is what actually makes the old store
        # paths collectable. Deliberately *not* pkgs.nix: the client must be
        # the one that owns /nix (Determinate's, via the default profile), not
        # a second nix from this flake's pinned nixpkgs.
        nix_bin=""
        for d in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin"; do
          if [ -x "$d/nix-collect-garbage" ]; then nix_bin="$d"; break; fi
        done

        if [ -z "$nix_bin" ]; then
          echo "nix-collect-garbage not found; skipping store cleanup"
        else
          export PATH="$nix_bin:$PATH"   # home-manager shells out to nix-env

          echo "Expiring Home Manager generations older than 7 days..."
          ${config.home.profileDirectory}/bin/home-manager expire-generations "-7 days" \
            || echo "expire-generations failed, continuing"

          # User-side collection only: the system profile and any root-owned
          # GC roots need `sudo nix-collect-garbage`, which a user timer
          # cannot do. Run that by hand if /nix keeps growing.
          echo "Collecting Nix store garbage older than 7 days..."
          "$nix_bin/nix-collect-garbage" --delete-older-than 7d \
            || echo "nix-collect-garbage failed, continuing"
        fi

        echo "[$(date)] Tools maintenance completed successfully"
      ''}";
      # Default TimeoutStartSec (90s) kills a first GC long before it
      # finishes; a week's worth of store paths can take many minutes.
      TimeoutStartSec = "45min";
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
