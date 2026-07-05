# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- This change attempts to exclude pipeline-worker operational state files from git, but contains a critical typo in .gitignore that prevents the actual directory from being ignored. Also includes configuration changes to Claude settings and tmux keybindings.

### Added

- Introduces a new Lua configuration module that enhances Neovim's Snacks file explorer with comprehensive mouse support: double-click to open/toggle files, ctrl-click for multi-selection, and right-click context menu with file operations (new, rename, copy, cut, paste, delete, open, refresh).
