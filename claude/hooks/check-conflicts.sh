#!/usr/bin/env bash
# Detect merge conflicts without triggering approval prompts.
# Replaces ad-hoc `rg '<<<<<<<'` scans and `git ls-files -u | awk` pipelines.
# Usage: check-conflicts.sh [path...]   (paths optional, defaults to whole tree)
set -euo pipefail

unmerged=$(git diff --name-only --diff-filter=U -- "$@" 2>/dev/null || true)

# `git diff --check` reports conflict markers and whitespace errors, exit 2 on markers.
markers=$(git diff --check -- "$@" 2>/dev/null || true)

if [ -z "$unmerged" ] && [ -z "$markers" ]; then
  echo "No merge conflicts."
  exit 0
fi

if [ -n "$unmerged" ]; then
  echo "Unmerged files:"
  printf '%s\n' "$unmerged"
fi

if [ -n "$markers" ]; then
  echo "Conflict markers:"
  printf '%s\n' "$markers"
fi

exit 1
