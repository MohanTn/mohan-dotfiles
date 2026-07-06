# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Migrated the whole repo to a Nix flake with standalone Home Manager: pinned toolchain (tmux, neovim, ripgrep, fd, jq, python3, node, gcc, dotnet, zed-editor, gh, fzf, bat, tree, htop, wget, unzip, lazygit, wslu), managed zsh + oh-my-zsh and git identity, and store-linked configs for Claude Code, tmux, and pi. `bootstrap.sh` (installs Nix, runs the first switch) replaces `install.sh`. Claude Code and the npm global CLIs stay on their native self-updating installers, bootstrapped by activation only when missing. Secrets move to untracked `~/.zshrc.local`.
- Hook runtime state moved from `~/.claude/hooks/state/` to `${XDG_STATE_HOME:-~/.local/state}/claude-hooks/` so the hooks directory can be a read-only Nix store link.
- Removed stale `test-hook.sh` entries for hooks deleted in the earlier consolidation (pre-compact, stop-ding, stop-speak); the selftest is green again and now runs in CI via `nix flake check` (new GitHub Actions workflow).

- Refactors the hooks system by introducing test-hook.sh (a comprehensive testing framework), sonar_lite.py (unified static analysis for TS/JS/C#), and removing less-critical hooks (bash-guard, read-cache, pre-compact, post-bash, stop-ding, stop-speak). Consolidates post-tool-use-edit to use sonar_lite instead of separate linting and citation checks.
- This change attempts to exclude pipeline-worker operational state files from git, but contains a critical typo in .gitignore that prevents the actual directory from being ignored. Also includes configuration changes to Claude settings and tmux keybindings.

### Added

- Introduces a new Lua configuration module that enhances Neovim's Snacks file explorer with comprehensive mouse support: double-click to open/toggle files, ctrl-click for multi-selection, and right-click context menu with file operations (new, rename, copy, cut, paste, delete, open, refresh).
