#!/usr/bin/env bash
# repo-map.sh <root> — write <root>/.claude/repo-map.md: a folder -> file ->
# symbol index of the whole repo, so an agent can orient from one Read instead
# of a fan-out of fd/rg/Glob calls.
#
# Symbols come from universal-ctags (nix/packages.nix), filtered to definition
# kinds; JSON keys, markdown headings and local variables are dropped as noise.
# Files with no extractable symbols are still listed, so the folder -> file half
# of the map is complete even for configs and docs.
#
# Regenerated on every SessionStart. Above MAX_FILES the symbol pass is skipped
# and only the folder -> file listing is written, so a monorepo degrades instead
# of blowing the hook timeout.
#
# Prints the written path on success. Best-effort: exits 0 with no output if it
# can't produce a map.
set -uo pipefail

MAX_FILES=4000
CTAGS_LANGS='Python,Sh,Zsh,JavaScript,TypeScript,Lua,Go,C#,Rust,Java,Ruby,C,C++,Nix,Perl,PHP,Kotlin,Scala,Swift,SQL,Make,CMake'
KIND_RE='^(function|method|class|struct|interface|member|module|enum|type|procedure|subroutine|alias|singleton method)$'

root="${1:-$PWD}"
[ -d "$root" ] || exit 0

# File list: tracked files in a git repo, else everything fd will show us.
# Both already exclude .git, and fd honours .gitignore, so build artefacts and
# node_modules stay out of the map either way.
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files=$(git -C "$root" ls-files 2>/dev/null)
else
  files=$(fd --type f --strip-cwd-prefix . "$root" 2>/dev/null)
fi
[ -n "$files" ] || exit 0
file_count=$(printf '%s\n' "$files" | grep -c .)

out_dir="$root/.claude"
out="$out_dir/repo-map.md"
mkdir -p "$out_dir" 2>/dev/null || exit 0

# Keep the generated map out of the user's history without inventing a
# .gitignore in a repo that has none.
ignore="$root/.gitignore"
if [ -f "$ignore" ] && ! grep -qxF '.claude/repo-map.md' "$ignore" 2>/dev/null; then
  printf '\n.claude/repo-map.md\n' >> "$ignore" 2>/dev/null
fi

symbols=""
symbol_count=0
if [ "$file_count" -le "$MAX_FILES" ] && command -v ctags >/dev/null 2>&1; then
  symbols=$(printf '%s\n' "$files" \
    | ctags -L - -x --_xformat='%F|%N|%K|%n' --languages="$CTAGS_LANGS" 2>/dev/null \
    | awk -F'|' -v kre="$KIND_RE" '$3 ~ kre' \
    | sort -t'|' -k1,1 -k4,4n)
  symbol_count=$(printf '%s\n' "$symbols" | grep -c .)
fi

{
  echo "# Repo map: $root"
  printf 'Generated %s | %s files' "$(date '+%Y-%m-%d %H:%M')" "$file_count"
  if [ "$symbol_count" -gt 0 ]; then
    printf ', %s symbols\n' "$symbol_count"
  elif [ "$file_count" -gt "$MAX_FILES" ]; then
    printf ' (over %s, symbol pass skipped)\n' "$MAX_FILES"
  else
    printf '\n'
  fi
  echo
  echo "Folder -> file -> symbol index of every tracked file. Symbols are shown as"
  echo "\`name (kind) :line\`; line numbers were current at generation time."
  echo "Files with no extractable symbols are grouped under 'Other files'."
  echo

  # Sort by directory then basename: a plain path sort interleaves a/b/c.py
  # between a/x.py and a/y.py, which would reopen the same folder heading twice.
  printf '%s\n' "$files" \
    | awk -F/ '{ base = $NF
                 dir = (NF == 1) ? "." : substr($0, 1, length($0) - length(base) - 1)
                 printf "%s\t%s\t%s\n", dir, base, $0 }' \
    | sort -t"$(printf '\t')" -k1,1 -k2,2 \
    | awk -F'\t' -v SYMS=<(printf '%s\n' "$symbols") '
      # -v, not a trailing SYMS=file operand: command-line assignments are
      # applied when awk reaches them in the argument list, i.e. after BEGIN.
      BEGIN { while ((getline line < SYMS) > 0) {
                split(line, f, "|")
                sym[f[1]] = sym[f[1]] sprintf("- %s (%s) :%s\n", f[2], f[3], f[4])
              } }
      function flush_plain() {
        if (plain != "") { printf "\nOther files: %s\n", plain; plain = "" }
      }
      {
        dir = $1; base = $2; path = $3
        if (dir != cur) { flush_plain(); printf "\n## %s\n", dir; cur = dir }
        if (path in sym) { printf "\n### %s\n%s", base, sym[path] }
        else { plain = (plain == "") ? base : plain ", " base }
      }
      END { flush_plain() }
    '
} > "$out" 2>/dev/null || exit 0

printf '%s' "$out"
exit 0
