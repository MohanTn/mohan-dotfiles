# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The flake now dynamically reads the system username via `$USER` at eval time instead of being hardcoded to "mohan", making it work unchanged on any machine. All Nix invocations now require the `--impure` flag. Tmux and its configuration have been removed as an out-of-scope tool. Several unused LazyVim boilerplate files were deleted, and a file deletion keybinding was added to the Neovim file explorer.
- Refactor machine bootstrap into `setup.sh` with three commands: default apply (setup or update), `doctor` for drift audit without changes, and `upgrade` for bumping dependencies. Adds comprehensive testing via a new flake check that validates shellcheck and exercises doctor against synthetic profiles.
- Replaced `bootstrap.sh` with `setup.sh`, a single entry point for the machine lifecycle: the no-arg run installs Nix if missing and applies the Home Manager flake (also the update path; hand edits under `$HOME` are reverted with the edited copy kept as `*.hm-backup`), `setup.sh doctor` audits that every managed file is still served from the Nix store without changing anything, and `setup.sh upgrade` bumps flake inputs then applies. A new `setup-script` flake check shellchecks the script and unit-tests the doctor audit against a synthetic Home Manager profile.
- Migrated the whole repo to a Nix flake with standalone Home Manager: pinned toolchain (tmux, neovim, ripgrep, fd, jq, python3, node, gcc, dotnet, zed-editor, gh, fzf, bat, tree, htop, wget, unzip, lazygit, wslu), managed zsh + oh-my-zsh and git identity, and store-linked configs for Claude Code, tmux, and pi. `bootstrap.sh` (installs Nix, runs the first switch) replaces `install.sh`. Claude Code and the npm global CLIs stay on their native self-updating installers, bootstrapped by activation only when missing. Secrets move to untracked `~/.zshrc.local`.
- Hook runtime state moved from `~/.claude/hooks/state/` to `${XDG_STATE_HOME:-~/.local/state}/claude-hooks/` so the hooks directory can be a read-only Nix store link.
- Removed stale `test-hook.sh` entries for hooks deleted in the earlier consolidation (pre-compact, stop-ding, stop-speak); the selftest is green again and now runs in CI via `nix flake check` (new GitHub Actions workflow).
- Brings `pi/agent/extensions/hooks` back to parity with the claude/hooks consolidation: removes the pi-side equivalents of the dropped hooks (bash-guard, read-cache, output-trimmers, tts-ding, architecture hints, citation checks) and adds the sonar_lite.py gate. Fixes a latent bug where the ported project-digest generation was computed but never surfaced to the model; it's now injected once per session. Adds a matching unit test suite (`node:test` + `tsx`) for the extension's pure logic, and fixes `test-hook.sh selftest`, which had been failing 2/7 checks since it still referenced the just-removed `pre-compact.sh`/`stop-ding.sh`.

### Added

- Introduces a new Lua configuration module that enhances Neovim's Snacks file explorer with comprehensive mouse support: double-click to open/toggle files, ctrl-click for multi-selection, and right-click context menu with file operations (new, rename, copy, cut, paste, delete, open, refresh).
