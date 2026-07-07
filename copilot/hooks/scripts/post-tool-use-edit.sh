#!/usr/bin/env bash
# postToolUse: edit|create — import-resolution + type-check + build gates,
# ported from claude/hooks/post-tool-use-edit.sh. Copilot's postToolUse
# cannot block, so findings are returned as {additionalContext}, which is
# appended to the tool result the model sees. The claude version's edit
# generation counter and sonar-lite call are intentionally not ported: their
# consumers do not exist on the Copilot side.
input=$(cat)
export HOOK_INPUT="$input"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

file=$(tool_arg '.path // .file_path // .filePath')
[ -z "$file" ] && exit 0

report() {
  jq -n --arg ctx "$1" '{additionalContext: $ctx}'
  exit 0
}

file_dir=$(dirname "$file")
in_git_repo=0
git -C "$file_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git_repo=1

case "$file" in
*.ts|*.tsx)
  if [ "$in_git_repo" = "1" ]; then
    # symbol-existence verifier (local relative imports only)
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
            report "Import '$mod' in $file does not resolve to an existing file."
          fi
          ;;
      esac
    done <<< "$new_imports"
  fi

  # type-check gate: discover nearest tsconfig.json by walking up from file_dir (max 6 levels)
  tsconfig_dir=""
  search_dir="$file_dir"
  for _ in 1 2 3 4 5 6; do
    if [ -f "$search_dir/tsconfig.json" ]; then
      tsconfig_dir="$search_dir"
      break
    fi
    parent=$(dirname "$search_dir")
    [ "$parent" = "$search_dir" ] && break
    search_dir="$parent"
  done

  if [ -n "$tsconfig_dir" ]; then
    tsc_bin=""
    if [ -x "$tsconfig_dir/node_modules/.bin/tsc" ]; then
      tsc_bin="$tsconfig_dir/node_modules/.bin/tsc"
    elif command -v npx >/dev/null 2>&1; then
      tsc_bin="npx --no-install tsc"
    fi
    if [ -n "$tsc_bin" ]; then
      errors=$(cd "$tsconfig_dir" && timeout 8 $tsc_bin --noEmit --pretty false -p "$tsconfig_dir" 2>&1 | grep "$(basename "$file")")
      if [ -n "$errors" ]; then
        log "post-edit: type errors in $file"
        report "Type errors introduced:
$errors"
      fi
    fi
  fi
  ;;
*.cs)
  # dotnet build gate, the C# analogue of the tsc gate above. There is no
  # equivalent of the relative-import check here: C# resolves by namespace via
  # project/assembly references, not relative file paths, so it doesn't map.
  if command -v dotnet >/dev/null 2>&1; then
    csproj_dir=""
    csproj_file=""
    search_dir="$file_dir"
    for _ in 1 2 3 4 5 6; do
      found=$(find "$search_dir" -maxdepth 1 -name "*.csproj" 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        csproj_dir="$search_dir"
        csproj_file="$found"
        break
      fi
      parent=$(dirname "$search_dir")
      [ "$parent" = "$search_dir" ] && break
      search_dir="$parent"
    done

    if [ -n "$csproj_dir" ]; then
      # --no-restore: a missing/stale restore produces NuGet errors that won't
      # mention this file's basename, so the filter below naturally ignores them
      # rather than false-flagging an unrelated restore problem.
      errors=$(cd "$csproj_dir" && timeout 20 dotnet build "$csproj_file" --no-restore -nologo -v q 2>&1 | grep -E 'error (CS|MSB)' | grep -F "$(basename "$file")")
      if [ -n "$errors" ]; then
        log "post-edit: build errors in $file"
        report "Build errors introduced:
$errors"
      fi
    fi
  fi
  ;;
esac

exit 0
