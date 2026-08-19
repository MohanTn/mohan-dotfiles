#!/usr/bin/env bash
# UserPromptSubmit — when the prompt looks like a request to hand-write
# boilerplate (a controller, repository, validator, ...), point at the
# ~/.agents/boilerplats/scaffold.js generator instead of writing it inline.
# Keyword-gated so it costs nothing on unrelated prompts.
input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)

# Noun list mirrors AGENT-HINT.md / boilerplate-guard.sh's mandate exactly
# (controller/repository/handler/validator/factory/commands/query/request/
# response/mapper/helper/di-injection) so a prompt naming any of them, in
# either phrasing shape, gets pointed at the generator before the model ever
# reaches for Write/Edit — the block message should be a rare backstop, not
# the primary way this gets discovered.
noun='(controller|repository|handler|validator|factory|mapper|quer(y|ies)|command(s)?|request|response|di.injection|helper|member)'
pattern="boilerplate|scaffold|\\b${noun}\\b.*\\b(class|endpoint|method|file|object|dto)\\b|\\b(new|generate|create|add|build|write)\\b.*\\b${noun}\\b|\\b(new|generate|create|add|build|write)\\b.*\\b(endpoint|route|crud)\\b"
if printf '%s' "$prompt" | grep -qiE "$pattern"; then
  hint_file="$HOME/.agents/boilerplats/AGENT-HINT.md"
  if [ -f "$hint_file" ]; then
    cat "$hint_file"
  else
    echo "Boilerplate generator available at ~/.agents/boilerplats/scaffold.js (run 'home-manager switch --impure' if that path doesn't exist yet)."
  fi
fi
exit 0
