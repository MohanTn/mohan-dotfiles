#!/usr/bin/env bash
# PreToolUse: Edit|Write — deterministic enforcement of the boilerplate mandate
# (agents/boilerplats/AGENT-HINT.md), rename-proof by design:
#   Write (new/empty file): boilerplate is detected by FILENAME (controller/
#     repository/... suffix) OR by CONTENT (signatures.grep, the boilerplate
#     shapes the templates produce), so renaming request.ts to payload.ts does
#     not evade the gate. Either match requires the scaffold:inject marker,
#     i.e. the shell must come from the generator. No override flag exists.
#   Write (overwrite): a marker the file already has must be kept.
#   Edit: removing the scaffold:inject marker is blocked on any code file, and
#     an edit that ADDS a member (method/function/endpoint declaration) to a
#     boilerplate-shaped file is blocked so it goes through the generator
#     instead. That is the brownfield half: scaffold_inject adopts a legacy
#     file on first touch, so markers spread by ongoing discovery, one worked-on
#     file at a time, never a bulk bootstrap. Editing the BODY of an existing
#     member is untouched, so bugfixing legacy code stays free.
# scaffold.js itself writes through Bash, so it is never caught here. The Bash
# workaround (cat > file <<EOF) is closed separately by bash-write-guard.sh.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$file" ] || exit 0

marker='scaffold:inject'
# Shipped next to this script (see the file's own header for why), so the
# content check is available wherever the guard runs.
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sig_file="$hook_dir/boilerplate-signatures.grep"
member_file="$hook_dir/boilerplate-members.grep"
name_re='(controller|repository|handler|validator|factory|mapper|query|command|request|response)\.(cs|ts|tsx|js|jsx|mjs|cjs|py|go)$'
code_re='\.(cs|ts|tsx|js|jsx|mjs|cjs|py|go|sh)$'

deny() {
  log "boilerplate-guard: $1 ($file)"
  printf '%s\n' "$2" >&2
  exit 2
}

# Marker rules apply to any code file — the marker itself flags the file as
# generator-managed, regardless of what the file is called.
printf '%s' "$file" | grep -qiE "$code_re" || exit 0

# Test files are exempt: a test for the generator (or for any controller/
# repository) necessarily contains boilerplate-shaped fixture strings, so the
# content signatures match every time and adding a test case looks like adding
# a member. Tests are not boilerplate and are never scaffolded, so gating them
# only produces false positives — this was found by the guard blocking a new
# case being added to boilerplats' own core.test.js.
test_re='(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.[A-Za-z]+$|_test\.(go|py)$|(^|/)test_[^/]+\.py$|Tests?\.cs$'
printf '%s' "$file" | grep -qE "$test_re" && exit 0

# Strips comments/blank lines so they aren't matched as literal patterns.
patterns_of() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

# Count member declarations in a blob of code.
count_members() {
  [ -f "$member_file" ] || { echo 0; return; }
  # grep -c prints 0 and exits 1 on no match, so capture rather than `|| echo 0`
  # (which would emit "0\n0" and break the numeric comparison below).
  local n
  n=$(printf '%s\n' "$1" | grep -cE -f <(patterns_of "$member_file") 2>/dev/null)
  printf '%s' "${n:-0}"
}

# Is this path boilerplate, by name or by the content already on disk?
file_is_boilerplate() {
  printf '%s' "$file" | grep -qiE "$name_re" && return 0
  [ -f "$file" ] && [ -f "$sig_file" ] || return 1
  grep -qE -f <(patterns_of "$sig_file") "$file" 2>/dev/null
}

if [ "$tool_name" = "Edit" ]; then
  old=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
  new=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
  if printf '%s' "$old" | grep -q "$marker" && ! printf '%s' "$new" | grep -q "$marker"; then
    deny "blocked marker removal" \
      "Blocked: this edit removes the $marker marker. Keep the marker in place — scaffold_inject (or scaffold.js --inject) inserts new members above it. Re-apply the edit with the marker retained."
  fi

  # Adding a member by hand is what the generator exists to prevent — in
  # legacy files too, which is why scaffold_inject adopts them on first touch.
  old_members=$(count_members "$old")
  new_members=$(count_members "$new")
  if [ "$new_members" -gt "$old_members" ] && file_is_boilerplate; then
    if grep -q "$marker" "$file" 2>/dev/null; then
      adopt_note="This file is already adopted (it carries the $marker marker)."
    else
      adopt_note="This file has not been adopted yet — scaffold_inject will adopt it first (marker placed at the end of the enclosing block, reported back as markerLine), then inject. Only this file is touched; the rest of the codebase stays as it is."
    fi
    deny "blocked hand-written member (+$((new_members - old_members)))" \
"Blocked: this edit hand-writes a new member into a boilerplate file. Members must come from the generator.
$adopt_note

Use:
  scaffold_inject { lang, template: \"member\", out: \"$file\", data: { Signature: \"<the declaration>\" } }
or, without MCP:
  node ~/.agents/boilerplats/scaffold.js --lang <lang> --template member --out '$file' --data '{\"Signature\":\"<the declaration>\"}' --inject --json
Then fill in the body with an ordinary Edit — changing the body of an existing member is never blocked. If the marker would land in the wrong scope, pass anchor (a line number or a unique snippet it should precede)."
  fi
  exit 0
fi

[ "$tool_name" = "Write" ] || exit 0
content=$(printf '%s' "$input" | jq -r '.tool_input.content // empty' 2>/dev/null)

if [ -f "$file" ] && [ -s "$file" ]; then
  # Overwrite of an existing file: only rule is that a marker, once there, stays.
  if grep -q "$marker" "$file" && ! printf '%s' "$content" | grep -q "$marker"; then
    deny "blocked marker-dropping overwrite" \
      "Blocked: this overwrite drops the $marker marker the file currently has. Keep the marker so scaffold_inject keeps working."
  fi
  exit 0
fi

# New or empty file: generator output always carries the marker, so a marked
# shell passes regardless of how boilerplate-ness was detected.
printf '%s' "$content" | grep -q "$marker" && exit 0

matched_sig=''
if [ -f "$sig_file" ]; then
  matched_sig=$(printf '%s' "$content" | grep -oE -f <(patterns_of "$sig_file") 2>/dev/null | head -1)
fi

if printf '%s' "$file" | grep -qiE "$name_re"; then
  reason="its name marks it as boilerplate"
elif [ -n "$matched_sig" ]; then
  reason="its content matches the boilerplate signature \"$matched_sig\" (renaming the file does not exempt it)"
else
  exit 0
fi

deny "blocked hand-written boilerplate ($reason)" \
"Blocked: boilerplate files must be created with the generator, not hand-written — $reason.
Create the shell with the scaffold MCP tool:
  scaffold_create { lang, template, out, data }   (scaffold_describe lists each template's fields)
or, without MCP:
  node ~/.agents/boilerplats/scaffold.js --lang <csharp|typescript|javascript|python|go> --template <controller|repository|handler|validator|factory|mapper|query|commands|request|response> --out <path> --data '<json>' --json
The result already contains the full numbered file content and the fillable lines — do not re-read the file; fill in the logic with Edit above the scaffold:inject marker. To add a member to an existing scaffold-marked file, use scaffold_inject with template \"member\".
See ~/.agents/boilerplats/AGENT-HINT.md for template data fields."
