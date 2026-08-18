#!/usr/bin/env bash
# Generate a folder → file → symbol index of the entire repository as .claude/repo-map.md.
# Allows agents to orient from a single Read of this index instead of multiple filesystem
# queries (fd, rg, grep). Runs on SessionStart; best-effort, does not error if generation fails.
# Usage: repo-map.sh [root_directory]
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
  # ctags has to run from $root: the file list is relative to it (git ls-files
  # prints repo-relative paths), so resolving those against the caller's PWD
  # instead silently finds nothing and degrades the map to a bare file listing
  # with no error. That happened to work only while the hook's PWD and $root
  # coincided, which is not guaranteed — session-start.sh takes cwd from the
  # payload, and the Copilot/Pi adapters invoke it from wherever the tool
  # was launched.
  symbols=$(printf '%s\n' "$files" \
    | (cd "$root" && ctags -L - -x --_xformat='%F|%N|%K|%n' --languages="$CTAGS_LANGS" 2>/dev/null) \
    | awk -F'|' -v kre="$KIND_RE" '$3 ~ kre' \
    | sort -t'|' -k1,1 -k4,4n)
  symbol_count=$(printf '%s\n' "$symbols" | grep -c .)
fi

{
  printf '# repo-map %s | %s files' "$root" "$file_count"
  if [ "$symbol_count" -gt 0 ]; then
    printf ', %s syms\n' "$symbol_count"
  elif [ "$file_count" -gt "$MAX_FILES" ]; then
    printf ' (>%s, syms skipped)\n' "$MAX_FILES"
  else
    printf '\n'
  fi
  printf 'fmt: dir/ then "file: name:line ..."; "+" line lists files with no symbols\n'

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
                sym[f[1]] = sym[f[1]] sprintf("%s:%s ", f[2], f[4])
              } }
      function flush_plain() {
        if (plain != "") { printf "+%s\n", plain; plain = "" }
      }
      {
        dir = $1; base = $2; path = $3
        if (dir != cur) { flush_plain(); printf "\n%s/\n", dir; cur = dir }
        if (path in sym) { s = sym[path]; sub(/ $/, "", s); printf "%s: %s\n", base, s }
        else { plain = (plain == "") ? base : plain " " base }
      }
      END { flush_plain() }
    '
} > "$out" 2>/dev/null || exit 0

printf '%s' "$out"
exit 0
