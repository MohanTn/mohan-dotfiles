# Shell configuration shared by nix/zsh.nix and nix/bash.nix.
#
# ./setup-packages.sh asks which shell to use (customPackages.enableZsh);
# whichever one wins gets the same aliases, helper functions, editor and
# colours from here. The only pieces that stay zsh-only are the ones with no
# bash counterpart: the oh-my-posh prompt, the zinit plugin stack
# (autosuggestions, syntax highlighting, fzf-tab, history-substring-search)
# and the zsh-specific history/completion hooks.
#
# Imported as a plain function, not a Home Manager module, so both shell
# modules interpolate the *same* strings instead of keeping two hand-synced
# copies. Every snippet below must therefore be valid in bash and zsh alike:
# no `[[ ]]`-only zsh syntax, no zsh-only job-control operators, and any
# script referenced by helperSources is kept bash-compatible on purpose (the
# shell-parity flake check parses all of them under both shells).
{ config, lib }:

let
  cfg = config.customPackages;
in
{
  aliases = {
    # `cc`: sonnet with the stock Claude Code system prompt fully replaced by
    # agents/lean-system-prompt.md (terse output, rg/fd over grep/find, Bash
    # only as a fallback). The prompt restates the pieces the ~/.claude hooks
    # depend on (GOAL/GOAL_CHECK, repo-map.md), since the default prompt is
    # gone. Pi loads the same file as
    # ~/.pi/agent/SYSTEM.md (see nix/pi.nix).
    cc = "claude --model sonnet --system-prompt-file ${../agents/lean-system-prompt.md} --allowed-tools \"Bash(git *)\" \"Bash(fd *)\" \"Bash(rg *)\" \"Bash(npm *)\" \"Bash(python3 *)\" Edit Write";
    # Mirrors claude/settings.json's permissions.allow (Bash(rg *), Bash(git
    # diff *)) for Copilot CLI, which has no persisted settings.json
    # equivalent of that allowlist (only the --allow-tool flag, confirmed
    # against `copilot help permissions`), so this self-referential alias is
    # the only reproducible way to carry it over. Pi needs no counterpart:
    # it has no default tool-confirmation prompt at all (docs/security.md),
    # so rg/git diff already run unprompted there.
    copilot = "copilot --allow-tool 'shell(rg:*)' --allow-tool 'shell(git diff:*)'";
    repo = "cd $HOME/REPO";
    # eza (nix/packages.nix): -la renders as a headered table instead of
    # GNU ls's bare column list; plain `ls`/other flags behave the same.
    ls = "eza --color=auto --header";
  };

  # Auto-start tmux for real interactive terminals, but only when tmux was
  # opted into (./setup-packages.sh -> enableTmux); nix/tmux.nix installs
  # nothing otherwise, so this block would find no tmux on PATH anyway and
  # is left out entirely rather than relying on that.
  #
  # Runs first in the rc file and uses exec so the outer shell is replaced
  # before plugins/completions load, instead of paying that cost twice. No
  # -A/-s here: each new terminal window gets its own fresh, independently
  # named session instead of every window piling into one shared session.
  # Guards, in order: interactive shell, attached to a tty, not already
  # inside tmux (nvim :terminal, nested shells), tmux on PATH, and an opt-out
  # for editor/agent shells that drive the shell programmatically and would
  # break if swallowed by a TUI.
  # `[[ ]]` with `==` pattern matching behaves identically in bash and zsh,
  # so this one block serves both rc files.
  tmuxAutostart = lib.optionalString cfg.enableTmux ''
    if [[ $- == *i* ]] && [[ -t 1 ]] && [[ -z $TMUX ]] \
      && [[ -z $NO_TMUX ]] && [[ -z $CLAUDECODE ]] && [[ -z $INSIDE_EMACS ]] \
      && [[ $TERM_PROGRAM != "vscode" ]] && [[ $TERM != "dumb" ]] \
      && command -v tmux > /dev/null; then
      exec tmux new-session
    fi
  '';

  # nvim as editor (plain vim over SSH)
  editor = ''
    if [ -n "''${SSH_CONNECTION:-}" ]; then
      export EDITOR='vim'
    else
      export EDITOR='nvim'
    fi
  '';

  # Default `ls` directory blue (di=01;34) is too dark to read on a dark
  # background; override to a brighter cyan, keep everything else default.
  lsColors = ''
    command -v dircolors >/dev/null 2>&1 && eval "$(dircolors -b)"
    export LS_COLORS="''${LS_COLORS}:di=01;36"
  '';

  # Function libraries. Each file is POSIX/bash-compatible so both shells can
  # source it; the shell-parity flake check parses them under bash and zsh.
  helperSources = ''
    # `axi` wrapper for chrome-devtools-axi: uses Google Chrome when
    # installed (setup.sh handles that on apt machines), otherwise starts a
    # debug Chromium and points the bridge at it.
    . ${../zsh/chrome-devtools-axi.zsh}

    # `agent-box`/`claude-box`/`copilot-box`/`pi-box`: run an agent CLI
    # fully containerized against the current directory (see docker/).
    . ${../zsh/agent-containers.zsh}

    # `gcm`/`mri`: local-model commit-message and MR-intent helpers backed
    # by little-coder + llama.cpp (install is opt-in via
    # nix/little-coder.nix's enableLittleCoder; the functions error
    # helpfully when it's off).
    . ${../zsh/little-coder.zsh}

    # Homebrew on PATH when installed (opt-in via nix/homebrew.nix's
    # enableHomebrew); no-op otherwise. Sourced after the Nix paths are set
    # so brew's bin lands behind them, never shadowing the base toolchain.
    . ${../zsh/homebrew.zsh}

    # `fkill`: fuzzy-pick a listening port/service/PID from lsof and kill -9 it.
    . ${../zsh/fkill.zsh}
  '';

  # Legacy per-machine installs, kept working where they exist.
  # Fresh machines get dotnet and node from Nix instead.
  legacyToolchains = ''
    if [ -d "$HOME/.dotnet" ]; then
      export DOTNET_ROOT="$HOME/.dotnet"
      export PATH="$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools"
    fi
    export NVM_DIR="$HOME/.nvm"
    # Do not let an old NVM-selected Node shadow the declarative Nix
    # toolchain. NVM remains available on machines that have no Node on PATH.
    if [ -s "$NVM_DIR/nvm.sh" ] && ! command -v node >/dev/null 2>&1; then
      . "$NVM_DIR/nvm.sh"
    fi
  '';
}