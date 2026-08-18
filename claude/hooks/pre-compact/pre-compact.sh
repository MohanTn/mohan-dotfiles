#!/usr/bin/env bash
# PreCompact — replay the few facts a compaction is most likely to lose.
#
# Compaction summarizes the transcript, so tool history is the first thing to go:
# after it, the model routinely no longer knows which files it already changed or
# what the session was for. That's cheap to restore and expensive to rediscover,
# so this emits a small carry-forward block: the stated goal, the files edited
# this session (recorded by post-tool-use-edit.sh), and the working-tree diffstat.
#
# Output is bounded and advisory. Always exits 0.
input=$(cat)
export HOOK_INPUT="$input"
source "$HOME/.claude/hooks/lib/common.sh"

goal_file="$state_dir/goal.txt"
edited_file="$state_dir/edited_files"

edited=""
if [ -f "$edited_file" ]; then
  # newest first, deduped, capped: a long session can touch the same file often
  edited=$(tac "$edited_file" 2>/dev/null | awk '!seen[$0]++' | head -25)
fi

diffstat=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  diffstat=$(git -C "$cwd" diff --stat HEAD 2>/dev/null | tail -20)
fi

# Nothing worth carrying forward: stay silent rather than emit an empty shell.
if [ ! -f "$goal_file" ] && [ -z "$edited" ] && [ -z "$diffstat" ]; then
  exit 0
fi

{
  echo "<carry-forward>"
  echo "Context preserved across compaction. Do not re-derive these."
  if [ -f "$goal_file" ]; then
    echo "<goal>$(cat "$goal_file" 2>/dev/null)</goal>"
  fi
  if [ -n "$edited" ]; then
    echo "<files-edited-this-session>"
    printf '%s\n' "$edited"
    echo "</files-edited-this-session>"
  fi
  if [ -n "$diffstat" ]; then
    echo "<uncommitted-diffstat>"
    printf '%s\n' "$diffstat"
    echo "</uncommitted-diffstat>"
  fi
  echo "</carry-forward>"
}

log "pre-compact: emitted carry-forward block"
exit 0
