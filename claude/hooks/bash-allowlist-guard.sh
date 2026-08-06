#!/usr/bin/env bash
# PreToolUse: Bash — allowlist-only shell policy. Every command position in the
# call (pipeline stages, `;`/`&&` segments, command substitutions, subshells)
# must name an allowlisted binary; anything else is denied. Default-deny, so a
# command this parser misreads fails closed instead of running unchecked.
# Reused as-is by the Copilot and Pi hook adapters, like bash-write-guard.sh,
# so all three agents share one authored copy of the policy.
#
# Extend it, one bare binary name per line (`#` comments and blanks ignored):
#   ~/.claude/bash-allowlist       machine-wide
#   <cwd>/.claude/bash-allowlist   per project, adds to the machine-wide list
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

DEFAULT_ALLOWED="rg fd fdfind git npm npx node python3 python jq pytest go cargo make"

declare -A ALLOWED=()
for b in $DEFAULT_ALLOWED; do ALLOWED["$b"]=1; done
for f in "$HOME/.claude/bash-allowlist" "${cwd:-$PWD}/.claude/bash-allowlist"; do
  [ -r "$f" ] || continue
  while read -r line; do
    line="${line%%#*}"
    line="${line// /}"
    [ -n "$line" ] && ALLOWED["$line"]=1
  done < "$f"
done

# Prints one command-position word per line. Quote-aware: operators inside
# quotes are literal text, so `python3 -c "a; b"` is one command, not two.
# Redirection targets are skipped (they are filenames, not commands).
command_words() {
  local s="$1"
  local n=${#s} i c
  local word="" expect=1 quote="" skip_target=0

  flush() {
    [ -n "$word" ] || { word=""; return; }
    if [ "$skip_target" = 1 ]; then
      skip_target=0
    elif [ "$expect" = 1 ]; then
      case "$word" in
        [A-Za-z_]*=*) ;;   # leading VAR=value assignment, command comes later
        *) printf '%s\n' "$word"; expect=0 ;;
      esac
    fi
    word=""
  }

  for ((i = 0; i < n; i++)); do
    c=${s:i:1}
    if [ -n "$quote" ]; then
      if [ "$c" = "$quote" ]; then
        quote=""
      elif [ "$quote" = '"' ] && { [ "$c" = '`' ] || { [ "$c" = '$' ] && [ "${s:i+1:1}" = '(' ]; }; }; then
        # a substitution opens a fresh command position even inside "..."
        [ "$c" = '$' ] && ((i++))
        flush; expect=1; skip_target=0
      else
        word+="$c"
      fi
      continue
    fi
    case "$c" in
      "'" | '"') quote="$c" ;;
      '\') ((i++)); word+="${s:i:1}" ;;
      ';' | '|' | '&' | '(' | ')' | '{' | '}' | '`' | $'\n')
        # `2>&1`: the & belongs to the redirection target, not a new command
        if [ "$skip_target" = 1 ] && [ "$c" = '&' ]; then word+="$c"; continue; fi
        flush; expect=1; skip_target=0 ;;
      '>' | '<')
        [ "${s:i+1:1}" = '(' ] && continue   # process substitution: '(' opens it
        if [ "$skip_target" = 1 ]; then continue; fi   # the second > of >>
        flush; skip_target=1 ;;
      ' ' | $'\t') flush ;;
      *) word+="$c" ;;
    esac
  done
  flush
}

denied=""
while read -r w; do
  [ -n "$w" ] || continue
  bin="${w##*/}"
  [ -n "${ALLOWED[$bin]:-}" ] && continue
  denied="$bin"   # report the first offender, not the last
  break
done < <(command_words "$cmd")

[ -n "$denied" ] || exit 0

log "bash-allowlist-guard: blocked non-allowlisted command '$denied'"
{
  echo "Blocked: '$denied' is not on the Bash allowlist, and shell access is allowlist-only."
  echo "Allowed: $(printf '%s\n' "${!ALLOWED[@]}" | sort | tr '\n' ' ')"
  echo "Use the Read/Edit/Write/search tools instead, or add the binary to"
  echo "~/.claude/bash-allowlist (machine-wide) or .claude/bash-allowlist (this project)."
} >&2
exit 2
