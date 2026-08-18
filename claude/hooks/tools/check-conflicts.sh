#!/usr/bin/env bash
# Detect merge conflicts without triggering approval prompts.
# Replaces ad-hoc `rg '<<<<<<<'` scans and `git ls-files -u | awk` pipelines.
# Usage: check-conflicts.sh [path...]   (paths optional, defaults to whole tree)
# Exit 1 on real conflicts (unmerged paths or leftover markers); whitespace
# diagnostics from `git diff --check` are reported but never fail the check.
set -euo pipefail

unmerged=$(git diff --name-only --diff-filter=U -- "$@" 2>/dev/null || true)

# `git diff --check` lines look like "path:line: <reason>". Leftover conflict
# markers say "conflict marker"; everything else is a whitespace diagnostic.
check=$(git diff --check -- "$@" 2>/dev/null || true)
markers=$(printf '%s' "$check" | grep -i 'conflict marker' || true)
whitespace=$(printf '%s' "$check" | grep -iv 'conflict marker' | grep -v '^$' || true)

conflict=0

if [ -n "$unmerged" ]; then
  echo "Unmerged files:"
  printf '%s\n' "$unmerged"
  conflict=1
fi

if [ -n "$markers" ]; then
  echo "Conflict markers:"
  printf '%s\n' "$markers"
  conflict=1
fi

if [ -n "$whitespace" ]; then
  echo "Whitespace errors (not conflicts):"
  printf '%s\n' "$whitespace"
fi

if [ "$conflict" -eq 0 ]; then
  echo "No merge conflicts."
  exit 0
fi
exit 1
