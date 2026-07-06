#!/usr/bin/env bash
# One-command machine setup: installs Nix if missing, then activates the
# Home Manager configuration in this repo. Safe to re-run; switching again
# is a no-op when nothing changed.
#
# Expected checkout location: ~/REPO/claude-code-helpers (nvim.nix links
# ~/.config/nvim straight at this checkout).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_DIR="$HOME/REPO/claude-code-helpers"

if [ "$SCRIPT_DIR" != "$EXPECTED_DIR" ]; then
  echo "! repo is at $SCRIPT_DIR but the config expects $EXPECTED_DIR" >&2
  echo "  clone it there (or move it) and re-run." >&2
  exit 1
fi

### Nix ########################################################################

if ! command -v nix >/dev/null 2>&1; then
  echo "> installing Nix (Determinate Systems installer)"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
  # make nix available in this shell
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
else
  echo "= nix already installed ($(nix --version))"
fi

### Home Manager switch ########################################################

echo "> activating home configuration (backing up conflicting files as *.hm-backup)"
nix run home-manager/release-25.05 -- switch -b hm-backup --flake "$SCRIPT_DIR"

### Login shell ################################################################

zsh_path="$(command -v zsh)"
current_shell="$(getent passwd "$USER" | cut -d: -f7)"
if [ "$(basename "$current_shell")" != "zsh" ]; then
  echo "> setting login shell to zsh (may prompt for your password)"
  chsh -s "$zsh_path" || echo "! chsh failed; run manually: chsh -s $zsh_path"
fi

### Reminders ##################################################################

cat <<'EOF'

Done. Reminders:
  * Secrets are NOT managed by this repo. Create ~/.zshrc.local with, e.g.:
      export PIPELINE_WORKER_GITHUB_TOKEN="..."
  * Docker (the daemon) is a system service and stays a manual install:
      https://docs.docker.com/engine/install/
  * Open a new terminal (or run 'exec zsh') to pick up the new environment.
EOF
