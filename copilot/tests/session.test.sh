#!/usr/bin/env bash
# session-start.sh and user-prompt-submit.sh — the two hooks whose whole job is
# what they emit (a context block) or deliberately do not emit (nothing).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sid="copilot-selftest-session"
rm -rf "${STATE_HOME:?}/$sid"

expect_out "session-start emits the project digest" session-start.sh \
  "$(jq -n --arg sid "$sid" '{sessionId:$sid, cwd:"/tmp", source:"startup"}')" \
  '.additionalContext | contains("Project digest")'

# hybrid-retrieval warm-up line rides along in additionalContext, since
# Copilot's sessionStart has no user-visible field. A fake binary on PATH
# answers `ensure` (absolute shebang: the nix check sandbox has no /usr/bin/env).
fake_bin=$(mktemp -d)
printf '#!%s\necho indexing\n' "$(command -v bash)" > "$fake_bin/hybrid-retrieval"
chmod +x "$fake_bin/hybrid-retrieval"
PATH="$fake_bin:$PATH" expect_out "session-start relays the retrieval indexing notice" session-start.sh \
  "$(jq -n --arg sid "$sid" '{sessionId:$sid, cwd:"/tmp", source:"startup"}')" \
  '.additionalContext | contains("used starting next session")'
rm -rf "$fake_bin"

# user-prompt-submit is state-reset only: no decision, no context, exit 0.
expect_silent "user-prompt-submit exits 0 with no output" user-prompt-submit.sh \
  "$(jq -n --arg sid "$sid" '{sessionId:$sid, cwd:"/tmp", prompt:"hello"}')"

rm -rf "${STATE_HOME:?}/$sid"
summary
