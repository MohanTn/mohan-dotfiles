#!/usr/bin/env bash
# pre-compact.sh — Copilot discards this hook's own output, so it stashes the
# carry-forward block in state and the next userPromptSubmitted flushes it.
# Driven off a git repo with an uncommitted change, one of the things
# pre-compact.sh replays.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sid="copilot-selftest-compact"
rm -rf "${STATE_HOME:?}/$sid"

pc_repo=$(mktemp -d)
git -C "$pc_repo" init -q 2>/dev/null
git -C "$pc_repo" config user.email selftest@example.com
git -C "$pc_repo" config user.name selftest
printf 'one\n' > "$pc_repo/a.txt"
git -C "$pc_repo" add a.txt
git -C "$pc_repo" commit -qm baseline
printf 'two\n' > "$pc_repo/a.txt"

expect_out "pre-compact returns an empty decision" pre-compact.sh \
  "$(jq -n --arg sid "$sid" --arg cwd "$pc_repo" '{sessionId:$sid, cwd:$cwd, trigger:"auto", transcriptPath:""}')" \
  '. == {}'

expect_out "the stashed carry-forward is flushed into the next prompt" \
  user-prompt-submit-context.sh \
  "$(jq -n --arg sid "$sid" --arg cwd "$pc_repo" '{sessionId:$sid, cwd:$cwd, prompt:"carry on with the work"}')" \
  '.additionalContext | contains("<carry-forward>") and contains("a.txt")'

# Second turn: with the stash consumed and no file matches for this prompt the
# hook emits nothing at all, so this is a plain text check — a jq assertion
# cannot run against empty stdout.
pc_second=$(run_hook user-prompt-submit-context.sh \
  "$(jq -n --arg sid "$sid" --arg cwd "$pc_repo" '{sessionId:$sid, cwd:$cwd, prompt:"carry on with the work"}')" 2>/dev/null)
refute_contains "the carry-forward is delivered once, not on every later prompt" \
  "$pc_second" "<carry-forward>"

rm -rf "$pc_repo" "${STATE_HOME:?}/$sid"
summary
