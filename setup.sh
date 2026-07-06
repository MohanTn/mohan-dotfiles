#!/usr/bin/env bash
# setup.sh: the single entry point for this machine's configuration.
#
#   ./setup.sh          set up a new machine OR apply config changes:
#                       installs Nix if missing, activates the Home Manager
#                       flake, sets the login shell to zsh, then audits for
#                       drift. Files changed outside Nix are reverted (the
#                       edited copy is kept next to them as *.hm-backup).
#   ./setup.sh doctor   audit only: verify every managed config is still
#                       served from the Nix store. Exits 1 on drift,
#                       changes nothing.
#   ./setup.sh upgrade  bump the pinned inputs (nixpkgs, home-manager) in
#                       flake.lock, then apply.
#
# The contract this script enforces: every config change goes through this
# repo and Nix. The live files under $HOME are read-only store symlinks,
# and each apply forcibly re-links anything that was replaced by hand.
#
# Expected checkout location: ~/REPO/claude-code-helpers (nvim.nix links
# ~/.config/nvim straight at this checkout).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_DIR="$HOME/REPO/claude-code-helpers"
# Only used before the first switch; afterwards the home-manager CLI from the
# flake-pinned generation takes over.
HM_FLAKE="home-manager/release-25.05"
HM_FILES="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager/home-files"

log()  { echo "> $*"; }
info() { echo "= $*"; }
warn() { echo "! $*" >&2; }

usage() {
  cat <<EOF
usage: ${0##*/} [command]

  (no command)  set up a new machine or apply config changes: installs Nix
                if missing, activates the Home Manager flake, sets the login
                shell to zsh, then audits for drift. Files changed outside
                Nix are reverted (edited copy kept as *.hm-backup).
  doctor        audit only: verify every managed config is still served from
                the Nix store. Exits 1 on drift, changes nothing.
  upgrade       update the pinned inputs (nixpkgs, home-manager) in
                flake.lock, then apply.
EOF
}

ensure_repo_location() {
  if [ "$SCRIPT_DIR" != "$EXPECTED_DIR" ]; then
    warn "repo is at $SCRIPT_DIR but the config expects $EXPECTED_DIR"
    warn "clone it there (or move it) and re-run."
    exit 1
  fi
}

ensure_nix() {
  # In non-login shells nix may be installed but not on PATH yet; source the
  # daemon profile before concluding it is missing.
  if ! command -v nix >/dev/null 2>&1 && [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
  if command -v nix >/dev/null 2>&1; then
    info "nix already installed ($(nix --version))"
    return
  fi
  log "installing Nix (Determinate Systems installer)"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
  # make nix available in this shell
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
}

switch() {
  log "activating home configuration (files changed outside Nix are reverted, kept as *.hm-backup)"
  if command -v home-manager >/dev/null 2>&1; then
    home-manager switch -b hm-backup --flake "$SCRIPT_DIR" --impure
  else
    nix run "$HM_FLAKE" -- switch -b hm-backup --flake "$SCRIPT_DIR" --impure
  fi
}

ensure_login_shell() {
  local zsh_path current_shell
  zsh_path="$(command -v zsh)"
  current_shell="$(getent passwd "$USER" | cut -d: -f7)"
  if [ "$(basename "$current_shell")" != "zsh" ]; then
    log "setting login shell to zsh (may prompt for your password)"
    chsh -s "$zsh_path" || warn "chsh failed; run manually: chsh -s $zsh_path"
  fi
}

# Walk every link point of the current Home Manager generation and verify the
# live file in $HOME still resolves to the same place. Catches: managed files
# deleted, replaced by hand-written copies, or re-pointed elsewhere. The two
# deliberate exceptions hold up on their own: ~/.config/nvim resolves to the
# repo checkout on both sides, and ~/.claude/settings.json is not a link point
# (it is a writable copy that Claude Code edits at runtime), so it is only
# reported informationally.
doctor() {
  if [ ! -e "$HM_FILES" ]; then
    warn "no Home Manager generation found; run '${0##*/}' first to set the machine up"
    return 1
  fi

  local drift=0 checked=0 managed rel live
  while IFS= read -r managed; do
    rel="${managed#"$HM_FILES/"}"
    live="$HOME/$rel"
    checked=$((checked + 1))
    if [ ! -e "$live" ] && [ ! -L "$live" ]; then
      warn "MISSING  $rel: managed file was deleted"
      drift=1
    elif [ "$(readlink -f -- "$live")" != "$(readlink -f -- "$managed")" ]; then
      warn "DRIFT    $rel: live file is no longer the Nix-managed version"
      drift=1
    fi
    if [ -e "$live.hm-backup" ] || [ -L "$live.hm-backup" ]; then
      info "leftover $rel.hm-backup: pre-Nix copy kept by an earlier apply; review and delete it"
    fi
  done < <(find -H "$HM_FILES" -type l)

  local repo_settings="$SCRIPT_DIR/claude/settings.json"
  local live_settings="$HOME/.claude/settings.json"
  if [ -f "$repo_settings" ] && [ -f "$live_settings" ] && ! cmp -s "$repo_settings" "$live_settings"; then
    info "live .claude/settings.json differs from the repo (expected: Claude Code writes permission grants into it)"
    info "to keep the runtime changes, copy them into claude/settings.json; the next apply refreshes the live file either way"
  fi

  if [ "$drift" -eq 0 ]; then
    log "doctor: $checked managed paths verified, all served from the Nix store"
  else
    warn "doctor: drift detected. Edit the file in $EXPECTED_DIR instead, then run '${0##*/}' to apply."
    warn "running '${0##*/}' now reverts the drifted files (hand-edited copies are kept as *.hm-backup)."
  fi
  return "$drift"
}

reminders() {
  cat <<'EOF'

Done. Reminders:
  * Every config change goes through this repo: edit here, re-run ./setup.sh,
    commit once 'nix flake check --impure' passes. Hand edits under $HOME are reverted
    on the next apply. 'setup.sh doctor' audits for such drift any time.
  * Secrets are NOT managed by this repo. Create ~/.zshrc.local with, e.g.:
      export PIPELINE_WORKER_GITHUB_TOKEN="..."
  * Docker (the daemon) is a system service and stays a manual install:
      https://docs.docker.com/engine/install/
  * Open a new terminal (or run 'exec zsh') to pick up the new environment.
EOF
}

apply() {
  ensure_repo_location
  ensure_nix
  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]; then
    info "repo has uncommitted changes; this apply includes them (run 'nix flake check --impure' before committing)"
  fi
  switch
  ensure_login_shell
  doctor
  reminders
}

upgrade() {
  ensure_repo_location
  ensure_nix
  log "updating pinned inputs (flake.lock)"
  (cd "$SCRIPT_DIR" && nix flake update)
  apply
  info "flake.lock changed; review with 'git -C $SCRIPT_DIR diff flake.lock' and commit it"
}

main() {
  case "${1:-apply}" in
    apply)          apply ;;
    doctor)         doctor ;;
    upgrade)        upgrade ;;
    -h|--help|help) usage ;;
    *)
      warn "unknown command: $1"
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
