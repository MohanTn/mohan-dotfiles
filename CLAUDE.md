# claude-code-helpers: repo guide

Personal machine setup as a Nix flake (standalone Home Manager, non-NixOS). The source of truth for every config is this repo; the live files under `$HOME` are read-only Nix store symlinks, refreshed by `home-manager switch --flake ~/REPO/claude-code-helpers`.

## Layout

* `flake.nix` pins nixpkgs and home-manager (release-25.05) and defines two checks: building the home configuration, and the hook regression suite.
* `nix/` holds one module per concern (`packages.nix`, `zsh.nix`, `git.nix`, `claude.nix`, `tmux.nix`, `nvim.nix`, `pi.nix`), all imported by `nix/home.nix`.
* `claude/`, `tmux/`, `nvim/`, `pi/` hold the actual config content the modules deploy.
* `bootstrap.sh` is the new-machine entry point (installs Nix, runs the first switch).

## Rules for changes

* A config edit in this repo does nothing until `home-manager switch` runs; always mention that when finishing a config change.
* `nix flake check` must pass before committing; it is also the CI gate (`.github/workflows/ci.yml`).
* Hook scripts must keep runtime state under `${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks` (see `claude/hooks/lib/common.sh`); `~/.claude/hooks` is a read-only store link, so writing next to the scripts fails.
* New hooks need an entry in `claude/hooks/test-hook.sh` (HOOK_INFO + default payload) and, when behavior is testable, a selftest case. The selftest runs sandboxed in CI via the flake check.
* Deployment exceptions, do not "fix" them: `~/.config/nvim` is an out-of-store symlink to this checkout (LazyVim writes `lazy-lock.json`), and `~/.claude/settings.json` is a writable copy (Claude Code writes permission grants into it).
* Secrets never enter this repo; machine-local values belong in `~/.zshrc.local` (sourced by `nix/zsh.nix`).
* Claude Code and the npm global CLIs are intentionally not pinned by Nix; they install natively via activation scripts only when missing.
