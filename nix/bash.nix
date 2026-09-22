# bash configuration, active only when ./setup-packages.sh was answered with
# "no" to the zsh question (customPackages.enableZsh = false). It mirrors
# nix/zsh.nix through nix/shell-common.nix: same aliases, same helper
# functions, same editor/colours/tmux auto-start, same machine-local override
# file (~/.bashrc.local instead of ~/.zshrc.local).
#
# Deliberately NOT carried over, because bash has no counterpart:
#   * the oh-my-posh Catppuccin prompt and its transient/width handling,
#     which are wired through zsh's precmd and TRAPWINCH hooks
#   * the zinit plugin stack (autosuggestions, syntax highlighting, fzf-tab,
#     history-substring-search, zsh-completions) and the zstyle settings
#     that configure it
#   * the "only keep successful commands in $HISTFILE" zshaddhistory/precmd
#     pair
# Everything else in this repo (fzf, zoxide, the Nix toolchain, the agent
# harnesses, tmux) is shell-agnostic and works unchanged.
{ config, lib, ... }:

let
  cfg = config.customPackages;
  shared = import ./shell-common.nix { inherit config lib; };
in
{
  programs.bash = lib.mkIf (!cfg.enableZsh) {
    enable = true;
    # bash-completion, the closest thing to the zsh-completions plugin.
    enableCompletion = true;

    shellAliases = shared.aliases;

    historySize = 50000;
    historyFileSize = 50000;
    historyFile = "$HOME/.bash_history";
    # erasedups is bash's HISTCONTROL analogue of zsh's ignoreAllDups +
    # saveNoDups: an older copy of a repeated command is dropped rather than
    # accumulating. ignorespace skips entries starting with a space.
    historyControl = [ "ignoredups" "ignorespace" "erasedups" ];

    initExtra = ''
      ${shared.tmuxAutostart}

      # cdspell fixes small typos in a cd target, the practical half of zsh's
      # CORRECT; checkwinsize keeps $LINES/$COLUMNS current after a resize.
      shopt -s cdspell checkwinsize

      ${shared.editor}

      # Space triggers history expansion (e.g. `!!<space>` -> last command,
      # `!$<space>` -> last arg) instead of just inserting a literal space.
      # readline bindings only exist in an interactive shell.
      # Ctrl-X Ctrl-E (edit the command line in $EDITOR) is a bash default,
      # so unlike zsh it needs no binding here.
      if [[ $- == *i* ]]; then
        bind Space:magic-space
      fi

      ${shared.lsColors}

      # Auto-activate a Python venv (.venv/ or venv/) found directly in the
      # directory you cd into; deactivate on leaving it, but only if this
      # hook was the one that activated it, so a venv you sourced by hand
      # elsewhere is left alone.
      _auto_activate_venv() {
        local venv_path=""
        if [ -f .venv/bin/activate ]; then
          venv_path="$PWD/.venv"
        elif [ -f venv/bin/activate ]; then
          venv_path="$PWD/venv"
        fi

        if [ -n "$venv_path" ]; then
          if [ "''${VIRTUAL_ENV:-}" != "$venv_path" ]; then
            . "$venv_path/bin/activate"
            __auto_venv=1
          fi
        elif [ -n "''${VIRTUAL_ENV:-}" ] && [ -n "''${__auto_venv:-}" ]; then
          deactivate
          unset __auto_venv
        fi
      }

      # bash has no chpwd hook; PROMPT_COMMAND runs before every prompt,
      # which covers cd and anything else that moves $PWD. Appended
      # idempotently so a re-sourced .bashrc doesn't stack copies of it, and
      # so whatever else already owns PROMPT_COMMAND (zoxide, direnv) keeps
      # running.
      case "''${PROMPT_COMMAND:-}" in
        *_auto_activate_venv*) ;;
        *) PROMPT_COMMAND="_auto_activate_venv''${PROMPT_COMMAND:+;''${PROMPT_COMMAND}}" ;;
      esac
      _auto_activate_venv

      ${shared.helperSources}

      ${shared.legacyToolchains}

      # Machine-local secrets and overrides, never committed.
      # PIPELINE_WORKER_GITHUB_TOKEN and similar live here.
      [ -f "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
    '';
  };
}
