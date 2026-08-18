#!/usr/bin/env bash
# user-prompt-submit-context.sh — the wrapper around claude/hooks/user-prompt-submit/context-augment.py.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sid="copilot-selftest-ctx"
rm -rf "${STATE_HOME:?}/$sid"

# Regression: the wrapper must forward .prompt into the payload it hands
# context-augment.py. Without it that script hits its MIN_WORDS guard and
# returns nothing, so the hook silently emits no context at all. Asserting on a
# real augmentation (a temp repo holding a file the prompt names by path, which
# context-augment.py resolves without fd/fzf) is what makes the omission
# visible — an empty-output check would pass either way.
ctx_repo=$(mktemp -d)
git -C "$ctx_repo" init -q 2>/dev/null
printf 'class AuthService:\n    def login(self, user):\n        return True\n' \
  > "$ctx_repo/auth_service.py"

expect_out "user-prompt-submit-context forwards the prompt to context-augment" \
  user-prompt-submit-context.sh \
  "$(jq -n --arg sid "$sid" --arg cwd "$ctx_repo" \
    '{sessionId:$sid, cwd:$cwd, prompt:"Please fix AuthService login in auth_service.py now"}')" \
  '.additionalContext | contains("auth_service.py") and contains("class AuthService:")'

rm -rf "$ctx_repo" "${STATE_HOME:?}/$sid"
summary
