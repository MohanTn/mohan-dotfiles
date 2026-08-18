#!/usr/bin/env bash
# session-start.sh and user-prompt-submit.sh — the two hooks whose whole job is
# what they emit (a context block) or deliberately do not emit (nothing).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sid="copilot-selftest-session"
rm -rf "${STATE_HOME:?}/$sid"

expect_out "session-start emits the boilerplate-generator hint" session-start.sh \
  "$(jq -n --arg sid "$sid" '{sessionId:$sid, cwd:"/tmp", source:"startup"}')" \
  '.additionalContext | contains("scaffold.js")'

# user-prompt-submit is state-reset only: no decision, no context, exit 0.
expect_silent "user-prompt-submit exits 0 with no output" user-prompt-submit.sh \
  "$(jq -n --arg sid "$sid" '{sessionId:$sid, cwd:"/tmp", prompt:"hello"}')"

rm -rf "${STATE_HOME:?}/$sid"
summary
