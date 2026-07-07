#!/usr/bin/env zsh
# "Phosphor CRT" prompt: green-on-black, styled after old monochrome
# monitors, with a modern hint (color emoji, a live clock in the terminal's
# own title bar instead of on every line). Sourced from nix/zsh.nix.
#
# Git status is computed off the main thread via zle -F so a slow `git
# status` in a large repo never blocks typing; a spinner stands in for the
# branch segment until it resolves (sched's granularity is whole seconds, so
# it's only visibly animated in slow/large repos).

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

# Phosphor tiers: real dual/tri-trace CRTs shipped in a few distinct tube
# colors (P1 green, P3 amber); reusing that as per-field accent hues keeps
# the palette on-theme instead of turning the prompt into a rainbow.
typeset -g _crt_sep="%F{#23492f}"
typeset -g _crt_branch="%F{#55e6c1}"
typeset -g _crt_amber="%F{#e3c66b}"
typeset -g _crt_prompt="%F{#b6ffce}"
typeset -g _crt_reset="%f"

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
    (( ahead > 0 )) && sync+=" ${_crt_amber}↑${ahead}${_crt_reset}"
    (( behind > 0 )) && sync+=" ${_crt_amber}↓${behind}${_crt_reset}"
    _PROMPT_GIT_SEGMENT="  ${_crt_sep}::${_crt_reset} ${icon} ${_crt_branch}${branch}${_crt_reset}${sync}"
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
  _PROMPT_GIT_SEGMENT="  ${_crt_sep}::${_crt_reset} ${_crt_branch}${_prompt_spinner_frames[$((_prompt_spinner_idx + 1))]}${_crt_reset}"
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

# Terminal title doubles as the CRT "window banner": a live clock that
# updates once per prompt instead of being repeated on every line.
_prompt_set_title() {
  print -Pn '\e]0;%n@%m  🕐 %D{%H:%M:%S}\a'
}

_prompt_precmd() {
  if (( _prompt_cmd_start > 0 )); then
    local elapsed=$(( EPOCHSECONDS - _prompt_cmd_start ))
    _prompt_cmd_start=0
    if (( elapsed >= 3 )); then
      _PROMPT_DURATION_SEGMENT="${_crt_amber}⏱ ${elapsed}s${_crt_reset} "
    else
      _PROMPT_DURATION_SEGMENT=""
    fi
  fi
  _prompt_set_title
  _prompt_async_git_start
}

preexec_functions+=(_prompt_preexec)
precmd_functions+=(_prompt_precmd)

PROMPT='%F{#4a8f68}%n@%m${_crt_reset} ${_crt_sep}::${_crt_reset} 📁 %F{#7dffb0}%/${_crt_reset}${_PROMPT_GIT_SEGMENT}
${_crt_prompt}❯${_crt_reset} '
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
