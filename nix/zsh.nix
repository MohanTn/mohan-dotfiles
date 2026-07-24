{ config, pkgs, ... }:

{
  programs.zsh = {
    enable = true;

    shellAliases = {
      cc = "claude --model haiku --allowed-tools \"Bash(git *)\" \"Bash(fd *)\" \"Bash(rg *)\" \"Bash(npm *)\" \"Bash(python3 *)\" Edit Write";
      repo = "cd $HOME/REPO";
      ls = "ls --color=auto";
    };

    history = {
      size = 50000;
      save = 50000;
      path = "$HOME/.zsh_history";
      append = true;
      share = true; # already home-manager's default, kept explicit
      ignoreSpace = true; # skip entries starting with a space; already default
      ignoreDups = true; # skip immediate repeats; already default
      ignoreAllDups = true; # drop the older copy when a command repeats non-adjacently
      saveNoDups = true; # never write duplicate entries to the file
      expireDuplicatesFirst = true; # trim dups before unique entries once size is exceeded
    };

    initContent = ''
      setopt CORRECT

      # Only keep commands that succeeded in $HISTFILE. zshaddhistory fires
      # before the command runs (exit code isn't known yet), so this stashes
      # the line there and, in precmd (which runs after execution, once $?
      # is known), deletes it from the file on failure. It's left in the
      # in-memory list either way, so Up-arrow/Ctrl-R can still recall a
      # failed command to fix and retry within the same session; it just
      # won't persist to disk or sync to other sessions.
      # Known limitation: a multi-line command spans more than one physical
      # line in the file, so only its last line gets trimmed on failure.
      autoload -Uz add-zsh-hook

      __hist_pending_cmd=""
      _hist_stash_pending() { __hist_pending_cmd=$1; return 0 }
      add-zsh-hook zshaddhistory _hist_stash_pending

      _hist_drop_failed() {
        local exit_code=$?
        if (( exit_code != 0 )) && [[ -n $__hist_pending_cmd ]]; then
          fc -W
          sed -i '$ d' "$HISTFILE"
        fi
        __hist_pending_cmd=""
      }
      add-zsh-hook precmd _hist_drop_failed

      # zinit plugin manager: the core script comes from the Nix store (no
      # runtime self-clone); plugins zinit installs still land in the
      # writable ZINIT[HOME_DIR] default (~/.local/share/zinit) since they
      # aren't part of this repo's declarative config.
      source ${pkgs.zinit}/share/zinit/zinit.zsh

      # oh-my-posh prompt, based on its bundled Catppuccin Mocha theme
      # (matches tmux's @catppuccin_flavor in nix/tmux.nix and nvim's
      # colorscheme). Vendored locally, rather than read straight from the
      # Nix store copy, to add a right-aligned execution-time segment and a
      # transient prompt (collapses to just the closer glyph once a command
      # is submitted, keeping a dotted divider + last execution time on the
      # right, like p10k's transient prompt).
      eval "$(oh-my-posh init zsh --config ${../zsh/oh-my-posh-catppuccin-mocha.omp.json})"

      # Width-aware path segment. The theme's path max_width is a template
      # reading $COLUMNS, which zsh keeps current but doesn't export, so
      # oh-my-posh (a child process) can't see it unless we mark it exported.
      export COLUMNS

      # oh-my-posh bakes PS1 into a literal string in precmd, so a resize
      # leaves the on-screen prompt (and the right-aligned dotted filler)
      # stale until the next command. Re-render it on SIGWINCH while the
      # line editor is active so the path shortens as you drag the edge.
      TRAPWINCH() {
        if (( $+functions[_omp_get_prompt] )) && zle; then
          eval "$(_omp_get_prompt primary --eval)"
          zle reset-prompt
        fi
      }

      # Extra completion definitions. blockf stops zinit auto-adding the
      # plugin's fpath entries twice; home-manager's compinit already ran
      # before this block, so re-run it to pick the new completions up.
      zinit ice blockf
      zinit light zsh-users/zsh-completions

      # Case-insensitive completion matching (git ch<TAB> matches "checkout").
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

      autoload -Uz compinit && compinit

      # fzf-powered interactive menu for tab completion. Must load right
      # after compinit but before autosuggestions/syntax-highlighting below,
      # which wrap zle widgets fzf-tab also needs to hook.
      zinit light Aloxaf/fzf-tab

      # Preview pane: show the selected directory's contents, for cd and any
      # other completion whose candidate is a folder.
      zstyle ':fzf-tab:complete:*:*' fzf-preview '[[ -d $realpath ]] && tree -C -L 2 $realpath'

      # Autosuggestions from history as you type.
      zinit light zsh-users/zsh-autosuggestions

      # History search forward/backward: type a prefix, then Up/Down cycles
      # matching history entries instead of the whole list.
      zinit light zsh-users/zsh-history-substring-search
      bindkey '^[[A' history-substring-search-up
      bindkey '^[[B' history-substring-search-down

      # Command syntax highlighting. Must load last: it wraps every other
      # widget zinit installs above it, per the plugin's own requirement.
      zinit light zsh-users/zsh-syntax-highlighting

      # nvim as editor (plain vim over SSH)
      if [[ -n $SSH_CONNECTION ]]; then
        export EDITOR='vim'
      else
        export EDITOR='nvim'
      fi

      # Ctrl-X Ctrl-E: edit the current command buffer in $EDITOR, replacing
      # the line with whatever's saved on exit.
      autoload -Uz edit-command-line
      zle -N edit-command-line
      bindkey '^X^E' edit-command-line

      # Space triggers history expansion (e.g. `!!<space>` -> last command,
      # `!$<space>` -> last arg) instead of just inserting a literal space.
      bindkey ' ' magic-space

      # Auto-activate a Python venv (.venv/ or venv/) found directly in the
      # directory you cd into; deactivate on leaving it, but only if this
      # hook was the one that activated it, so a venv you sourced by hand
      # elsewhere is left alone.
      _auto_activate_venv() {
        local venv_path=""
        if [[ -f .venv/bin/activate ]]; then
          venv_path="$PWD/.venv"
        elif [[ -f venv/bin/activate ]]; then
          venv_path="$PWD/venv"
        fi

        if [[ -n $venv_path ]]; then
          if [[ "$VIRTUAL_ENV" != "$venv_path" ]]; then
            source "$venv_path/bin/activate"
            __auto_venv=1
          fi
        elif [[ -n $VIRTUAL_ENV && -n $__auto_venv ]]; then
          deactivate
          unset __auto_venv
        fi
      }
      add-zsh-hook chpwd _auto_activate_venv
      _auto_activate_venv

      # Legacy per-machine installs, kept working where they exist.
      # Fresh machines get dotnet and node from Nix instead.
      if [ -d "$HOME/.dotnet" ]; then
        export DOTNET_ROOT="$HOME/.dotnet"
        export PATH="$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools"
      fi
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

      # Default `ls` directory blue (di=01;34) is too dark to read on a dark
      # background; override to a brighter cyan, keep everything else default.
      command -v dircolors >/dev/null 2>&1 && eval "$(dircolors -b)"
      export LS_COLORS="''${LS_COLORS}:di=01;36"

      # Color the completion menu (file/dir listings, e.g. `ls <TAB>`) the
      # same way `ls --color` does, using the LS_COLORS set above.
      zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"

      # `axi` wrapper for chrome-devtools-axi: uses Google Chrome when
      # installed (setup.sh handles that on apt machines), otherwise starts a
      # debug Chromium and points the bridge at it.
      source ${../zsh/chrome-devtools-axi.zsh}

      # `agent-box`/`claude-box`/`copilot-box`/`pi-box`: run an agent CLI
      # fully containerized against the current directory (see docker/).
      source ${../zsh/agent-containers.zsh}

      # Machine-local secrets and overrides, never committed.
      # PIPELINE_WORKER_GITHUB_TOKEN and similar live here.
      [ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
    '';
  };

  # fuzzy history (ctrl-r) and file search (ctrl-t), wired into zsh
  programs.fzf.enable = true;

  # `z <query>` jumps to frecency-ranked directories; `zi` for interactive pick
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  home.sessionVariables = {
    LANG = "en_US.UTF-8";
    # npm global installs go to a user-writable prefix (the Nix store is
    # read-only); ~/.npm-global/bin is on home.sessionPath.
    NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
    # pnpm's global bin dir (pnpm link --global, pnpm add -g); the Nix store
    # pnpm binary can't write there itself, so it's declared here instead of
    # via `pnpm setup`. ~/.local/share/pnpm is on home.sessionPath.
    PNPM_HOME = "${config.home.homeDirectory}/.local/share/pnpm";
    FREEBUFF_MODE = "true";
    PIPELINE_WORKER_AGENT = "claude";
    PIPELINE_WORKER_FORGE = "github";
    PIPELINE_WORKER_INTENT_MODEL = "haiku";
    PIPELINE_WORKER_CLEANUP = "true";
    PIPELINE_WORKER_POLL_INTERVAL_SECONDS = "15";
    PIPELINE_WORKER_CLEANUP_EARLY = "true";
    PIPELINE_WORKER_UPDATE_CHANGELOG = "true";
    # PIPELINE_WORKER_GITHUB_TOKEN is a secret: set it in ~/.zshrc.local
  };
}
