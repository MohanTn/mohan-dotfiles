#!/usr/bin/env zsh
# Custom async prompt: emoji git status (computed off the main thread so a
# slow `git status` in a big repo never blocks typing), a colored badge line,
# and a reactive exit-code/duration line. Sourced from nix/zsh.nix.

setopt PROMPT_SUBST
zmodload zsh/datetime
zmodload zsh/sched

typeset -g _prompt_cmd_start=0
typeset -g _PROMPT_DURATION_SEGMENT=""
typeset -g _PROMPT_GIT_SEGMENT=""
typeset -g _prompt_git_fd=-1
typeset -g _prompt_spinner_active=0
typeset -g _prompt_spinner_idx=0
typeset -ga _prompt_spinner_frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# porcelain=2 --branch gives dirty files, branch name, and ahead/behind vs
# upstream (# branch.ab +N -M) in one call instead of three separate ones.
_prompt_async_git_worker() {
  local branch="" ahead=0 behind=0 dirty=0 line
  while IFS= read -r line; do
    case $line in
      '# branch.head '*)
        branch=${line#'# branch.head '}
        ;;
      '# branch.ab '*)
        local ab=${line#'# branch.ab '}
        local a=${ab%% *} b=${ab##* }
        ahead=${a#+}
        behind=${b#-}
        ;;
      '#'*) ;;
      *) dirty=1 ;;
    esac
  done < <(git status --porcelain=2 --branch 2>/dev/null)
  [[ -n $branch ]] || return
  if [[ $branch == '(detached)' ]]; then
    branch=$(git rev-parse --short HEAD 2>/dev/null)
    [[ -n $branch ]] || return
  fi
  print -r -- "${branch}|${dirty}|${ahead}|${behind}"
}

# zle -F delivers the worker's output without blocking the terminal; the fd is
# read exactly once since the worker prints a single line and exits.
_prompt_async_git_callback() {
  local line=""
  IFS= read -r -u $_prompt_git_fd line
  zle -F $_prompt_git_fd
  exec {_prompt_git_fd}<&-
  _prompt_git_fd=-1
  _prompt_spinner_active=0
  if [[ -n $line ]]; then
    local -a parts
    parts=("${(@s:|:)line}")
    local branch=$parts[1] dirty=$parts[2] ahead=$parts[3] behind=$parts[4]
    local icon sync=""
    if [[ $dirty == 1 ]]; then
      icon="🔥"
    else
      icon="🌿"
    fi
    (( ahead > 0 )) && sync+=" ↑${ahead}"
    (( behind > 0 )) && sync+=" ↓${behind}"
    _PROMPT_GIT_SEGMENT="  ${icon} ${branch}${sync}"
  else
    _PROMPT_GIT_SEGMENT=""
  fi
  zle && zle reset-prompt
}

# sched's minimum granularity is whole seconds, so this only becomes visible
# as an animated spinner in large/slow repos; fast repos resolve before it ticks.
_prompt_spinner_tick() {
  (( _prompt_spinner_active )) || return
  _prompt_spinner_idx=$(( (_prompt_spinner_idx + 1) % ${#_prompt_spinner_frames[@]} ))
  _PROMPT_GIT_SEGMENT="  ${_prompt_spinner_frames[$((_prompt_spinner_idx + 1))]}"
  zle && zle reset-prompt
  (( _prompt_spinner_active )) && sched +1 _prompt_spinner_tick
}

_prompt_async_git_start() {
  if (( _prompt_git_fd >= 0 )); then
    zle -F $_prompt_git_fd
    exec {_prompt_git_fd}<&-
    _prompt_git_fd=-1
  fi
  _prompt_spinner_active=1
  _prompt_spinner_idx=0
  exec {_prompt_git_fd}< <(_prompt_async_git_worker)
  zle -F $_prompt_git_fd _prompt_async_git_callback
  sched +1 _prompt_spinner_tick
}

_prompt_preexec() {
  _prompt_cmd_start=$EPOCHSECONDS
}

_prompt_precmd() {
  if (( _prompt_cmd_start > 0 )); then
    local elapsed=$(( EPOCHSECONDS - _prompt_cmd_start ))
    _prompt_cmd_start=0
    if (( elapsed >= 3 )); then
      _PROMPT_DURATION_SEGMENT="⏱ ${elapsed}s "
    else
      _PROMPT_DURATION_SEGMENT=""
    fi
  fi
  _prompt_async_git_start
}

preexec_functions+=(_prompt_preexec)
precmd_functions+=(_prompt_precmd)

PROMPT='%K{54}%F{255} 📁 %/${_PROMPT_GIT_SEGMENT}  🕐 %D{%Y-%m-%d %H:%M:%S} %f%k
%(?.%F{green}.%F{red})❯%f '
RPROMPT='${_PROMPT_DURATION_SEGMENT}%(?.✅.❌)'

if [[ -o interactive ]]; then
  _prompt_typewriter() {
    local msg="🚀 Welcome back, ${USER} — $(date '+%A, %b %d')"
    local i
    for (( i = 1; i <= ${#msg}; i++ )); do
      printf '%s' "${msg[$i]}"
      sleep 0.02
    done
    printf '\n'
  }
  _prompt_typewriter
fi
