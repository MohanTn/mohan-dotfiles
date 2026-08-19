{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.customPackages;

  # Where Homebrew's own installer puts things on Linux and macOS. Checked in
  # this order by both the activation below and zsh/homebrew.zsh.
  brewCandidates = [
    "/home/linuxbrew/.linuxbrew/bin/brew"
    "${config.home.homeDirectory}/.linuxbrew/bin/brew"
    "/opt/homebrew/bin/brew"
    "/usr/local/bin/brew"
  ];
in
{
  options.customPackages = {
    enableHomebrew = mkEnableOption "Homebrew package manager (brew)";

    brewPackages = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "gh" "awscli" ];
      description = ''
        Formulae installed with `brew install` on every activation. Already
        installed formulae are skipped, so this is idempotent. Nix stays the
        source of truth for the base toolchain (nix/packages.nix); use this
        only for things nixpkgs lacks or that must track upstream releases.
      '';
    };
  };

  config = mkIf cfg.enableHomebrew {
    home.activation.installHomebrew = hm.dag.entryAfter [ "writeBoundary" ] ''
      # glibc.bin provides `ldd`, which Homebrew's installer shells out to for
      # its Glibc-version check; without it on PATH the check can't run and
      # the installer refuses to proceed, misreporting Glibc as "too old"
      # even when it isn't. Activation runs with a minimal inherited PATH
      # (notably inside sandboxed agent shells, which don't carry /usr/bin),
      # so this can't rely on the ambient PATH the way it can on a normal
      # interactive shell.
      export PATH="${pkgs.curl}/bin:${pkgs.git}/bin:${pkgs.bash}/bin:${pkgs.glibc.bin}/bin:$PATH"

      (
        brew_bin=""
        for c in ${escapeShellArgs brewCandidates}; do
          if [ -x "$c" ]; then brew_bin="$c"; break; fi
        done

        if [ -z "$brew_bin" ]; then
          # Official installer: needs sudo (it owns /home/linuxbrew so the
          # prebuilt bottles apply) and refuses to run as root. NONINTERACTIVE
          # skips its confirmation prompt; the sudo password prompt stays.
          echo "Installing Homebrew (may prompt for your password)..."
          installer="$(mktemp)"
          # Safety net: guarantees the temp file is removed even if the
          # download or installer fails and the script exits early under
          # set -eu, before the explicit cleanup below is reached.
          trap 'rm -f "$installer"' EXIT
          # HEAD is intentionally unpinned: this is upstream Homebrew's own
          # documented bootstrap URL, and the installer itself resolves the
          # actual brew version to install. Bounded timeouts keep a stalled
          # or unreachable connection from hanging activation indefinitely.
          $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fsSL --connect-timeout 10 --max-time 300 -o "$installer" \
            https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
          NONINTERACTIVE=1 $DRY_RUN_CMD ${pkgs.bash}/bin/bash "$installer"
          $DRY_RUN_CMD rm -f "$installer"
          trap - EXIT
          for c in ${escapeShellArgs brewCandidates}; do
            if [ -x "$c" ]; then brew_bin="$c"; break; fi
          done
        fi

        [ -n "$brew_bin" ] || { echo "brew not found after install" >&2; exit 1; }
        eval "$("$brew_bin" shellenv)"
        echo "✓ Homebrew ready: $brew_bin"

        ${optionalString (cfg.brewPackages != [ ]) ''
          for f in ${escapeShellArgs cfg.brewPackages}; do
            if "$brew_bin" list --formula --versions "$f" >/dev/null 2>&1; then
              echo "brew: $f already installed"
            else
              echo "brew: installing $f"
              $DRY_RUN_CMD "$brew_bin" install "$f"
            fi
          done
        ''}
      ) || echo "Warning: Homebrew setup failed, continuing" >&2
    '';
  };
}
