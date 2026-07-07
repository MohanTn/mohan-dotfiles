# mohan-dotfiles: repo guide

Personal machine setup as a Nix flake (standalone Home Manager, non-NixOS). The source of truth for every config is this repo; the live files under `$HOME` are read-only Nix store symlinks, refreshed by `home-manager switch --flake ~/REPO/mohan-dotfiles --impure`.

## Layout

* `flake.nix` pins nixpkgs and home-manager (release-25.05), reads the account name from `$USER` at eval time (hence `--impure` everywhere below), and defines four checks: building the home configuration, the Claude and Copilot hook regression suites, and the `setup.sh` lint + doctor tests.
* `nix/` holds one module per concern (`packages.nix`, `zsh.nix`, `git.nix`, `claude.nix`, `copilot.nix`, `nvim.nix`, `pi.nix`), all imported by `nix/home.nix`.
* `claude/`, `copilot/`, `nvim/`, `pi/` hold the actual config content the modules deploy.
* `setup.sh` is the single entry point: no-arg run does new-machine setup and applies config changes (wraps `home-manager switch`), `setup.sh doctor` audits that every managed file is still served from the Nix store, `setup.sh upgrade` bumps flake inputs then applies. Its lint + doctor tests run as the `setup-script` flake check.

## Rules for changes

* A config edit in this repo does nothing until `home-manager switch --impure` runs; always mention that when finishing a config change.
* `nix flake check --impure` must pass before committing; it is also the CI gate (`.github/workflows/ci.yml`).
* Hook scripts must keep runtime state under `${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks` (see `claude/hooks/lib/common.sh`) or `.../copilot-hooks` (see `copilot/hooks/scripts/lib/common.sh`); `~/.claude/hooks` and `~/.copilot/hooks` are read-only store links, so writing next to the scripts fails.
* New hooks need an entry in the matching `test-hook.sh` (`claude/hooks/` or `copilot/hooks/`: HOOK_INFO + default payload) and, when behavior is testable, a selftest case. Both selftests run sandboxed in CI via the flake checks.
* `copilot/hooks` is a shell port of `claude/hooks` for Copilot CLI (camelCase payloads, JSON decisions on stdout instead of exit-2 blocks; see `copilot/hooks/mohan-hooks.json`); `pi/agent/extensions/hooks` is the TypeScript port. Keep the ports in sync when one changes.
* Deployment exceptions, do not "fix" them: `~/.config/nvim` is an out-of-store symlink to this checkout (LazyVim writes `lazy-lock.json`), and `~/.claude/settings.json` is a writable copy (Claude Code writes permission grants into it).
* Secrets never enter this repo; machine-local values belong in `~/.zshrc.local` (sourced by `nix/zsh.nix`). On first adoption on a machine, `setup.sh`'s `migrate_pre_nix_dotfiles` folds any pre-existing `~/.zshrc`/`~/.zshenv` content into `~/.zshrc.local` before Home Manager takes the files over, so nothing is silently lost.
* Claude Code and the npm global CLIs are intentionally not pinned by Nix; they install natively via activation scripts only when missing.
