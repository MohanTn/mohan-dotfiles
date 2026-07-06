# claude-code-helpers: repo guide

Personal machine setup as a Nix flake (standalone Home Manager, non-NixOS). The source of truth for every config is this repo; the live files under `$HOME` are read-only Nix store symlinks, refreshed by `home-manager switch --flake ~/REPO/claude-code-helpers --impure`.

## Layout

* `flake.nix` pins nixpkgs and home-manager (release-25.05), reads the account name from `$USER` at eval time (hence `--impure` everywhere below), and defines three checks: building the home configuration, the hook regression suite, and the `setup.sh` lint + doctor tests.
* `nix/` holds one module per concern (`packages.nix`, `zsh.nix`, `git.nix`, `claude.nix`, `nvim.nix`, `pi.nix`), all imported by `nix/home.nix`.
* `claude/`, `nvim/`, `pi/` hold the actual config content the modules deploy.
* `setup.sh` is the single entry point: no-arg run does new-machine setup and applies config changes (wraps `home-manager switch`), `setup.sh doctor` audits that every managed file is still served from the Nix store, `setup.sh upgrade` bumps flake inputs then applies. Its lint + doctor tests run as the `setup-script` flake check.

## Rules for changes

* A config edit in this repo does nothing until `home-manager switch --impure` runs; always mention that when finishing a config change.
* `nix flake check --impure` must pass before committing; it is also the CI gate (`.github/workflows/ci.yml`).
* Hook scripts must keep runtime state under `${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks` (see `claude/hooks/lib/common.sh`); `~/.claude/hooks` is a read-only store link, so writing next to the scripts fails.
* New hooks need an entry in `claude/hooks/test-hook.sh` (HOOK_INFO + default payload) and, when behavior is testable, a selftest case. The selftest runs sandboxed in CI via the flake check.
* Deployment exceptions, do not "fix" them: `~/.config/nvim` is an out-of-store symlink to this checkout (LazyVim writes `lazy-lock.json`), and `~/.claude/settings.json` is a writable copy (Claude Code writes permission grants into it).
* Secrets never enter this repo; machine-local values belong in `~/.zshrc.local` (sourced by `nix/zsh.nix`).
* Claude Code and the npm global CLIs are intentionally not pinned by Nix; they install natively via activation scripts only when missing.
