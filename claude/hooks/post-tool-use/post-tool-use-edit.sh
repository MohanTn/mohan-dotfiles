#!/usr/bin/env bash
# PostToolUse: Edit|Write — 2.1 dirty-flag + 3.1 symbol-existence
# No tsc/dotnet build gate here: a whole-project compile per edit times out on
# anything large (so it silently passes exactly where it's needed), and the
# basename grep it filtered errors with false-blocks on common names like
# index.ts. Compile errors are better caught by an explicit build the model runs.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file" ] && exit 0

# 2.1 — edit generation counter: every successful Edit/Write advances this so the
# Bash dedup/failure-memory guards can tell "no changes since X" apart per-command
# instead of via a single global flag any unrelated Bash call would clear.
gen_file="$state_dir/edit_gen"
gen=$(( $(cat "$gen_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$gen" > "$gen_file" 2>/dev/null

# Append to the touched-files list pre-compact.sh replays, so the set of files
# this session changed survives a compaction that drops the tool history.
printf '%s\n' "$file" >> "$state_dir/edited_files" 2>/dev/null

file_dir=$(dirname "$file")
in_git_repo=0
git -C "$file_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git_repo=1

case "$file" in
*.ts|*.tsx)
  if [ "$in_git_repo" = "1" ]; then
    # 3.1 — symbol-existence verifier (local relative imports only)
    new_imports=$(git -C "$file_dir" diff -- "$file" 2>/dev/null | grep '^+import' | grep -oE "from ['\"][^'\"]+['\"]")
    while IFS= read -r imp; do
      [ -z "$imp" ] && continue
      mod=$(printf '%s' "$imp" | sed -E "s/from ['\"](.+)['\"]/\1/")
      case "$mod" in
        .*)
          # Strip a trailing extension first: NodeNext/ESM TS projects commonly
          # import "./foo.js" for a source file that's actually "./foo.ts" —
          # checking "${resolved}.js.ts" etc. without stripping would false-positive.
          stripped="$mod"
          case "$stripped" in
            *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs) stripped="${stripped%.*}" ;;
          esac
          resolved="${file_dir}/${stripped}"
          if [ ! -f "${file_dir}/${mod}" ] && [ ! -f "${resolved}.ts" ] && [ ! -f "${resolved}.tsx" ] && [ ! -f "${resolved}/index.ts" ] && [ ! -f "${resolved}.js" ] && [ ! -f "${resolved}.jsx" ]; then
            log "post-edit: unresolved import '$mod' in $file"
            echo "Import '$mod' in $file does not resolve to an existing file." >&2
            exit 2
          fi
          ;;
      esac
    done <<< "$new_imports"
  fi
  ;;
esac

exit 0
