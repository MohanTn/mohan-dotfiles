#!/usr/bin/env bash
# try-context-augment.sh — feed a real prompt to context-augment.py and see
# exactly what it would inject, with timing. For eyeballing quality, not CI
# (see test_context_augment.py for the unit/regression suite).
#
# Usage:
#   try-context-augment.sh "Fix the AuthService login bug in src/auth.py"
#   try-context-augment.sh "some prompt" /path/to/other/repo
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HOOKS_DIR/context-augment.py"

prompt="${1:-}"
cwd="${2:-$PWD}"

if [ -z "$prompt" ]; then
  echo "Usage: $(basename "$0") \"<prompt>\" [cwd]" >&2
  exit 2
fi

payload=$(jq -n --arg prompt "$prompt" --arg cwd "$cwd" \
  '{prompt:$prompt, cwd:$cwd}')

echo "==> Payload:"
printf '%s\n' "$payload" | jq .

start=$(date +%s.%N)
output=$(printf '%s' "$payload" | python3 "$SCRIPT")
status=$?
end=$(date +%s.%N)

echo "==> Exit: $status   Time: $(printf '%.3f' "$(echo "$end - $start" | bc)")s"
echo "==> Output:"
if [ -z "$output" ]; then
  echo "(empty — no augmentation emitted)"
else
  printf '%s\n' "$output"
fi
