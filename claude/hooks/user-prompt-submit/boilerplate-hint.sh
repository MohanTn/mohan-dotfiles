#!/usr/bin/env bash
# UserPromptSubmit — when the prompt looks like a request to hand-write
# boilerplate (a controller, repository, validator, ...), point at the
# ~/.agents/boilerplats/scaffold.js generator instead of writing it inline.
# Keyword-gated so it costs nothing on unrelated prompts.
input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)

pattern='boilerplate|scaffold|\b(controller|repository|handler|validator|factory|mapper|di.injection)\b.*\b(class|endpoint|method|file)\b|\b(new|generate|create|add|build|write)\b.*\b(controller|repository|handler|validator|factory|mapper|endpoint|route|crud)\b'
if printf '%s' "$prompt" | grep -qiE "$pattern"; then
  hint_file="$HOME/.agents/boilerplats/AGENT-HINT.md"
  if [ -f "$hint_file" ]; then
    cat "$hint_file"
  else
    echo "Boilerplate generator available at ~/.agents/boilerplats/scaffold.js (run 'home-manager switch --impure' if that path doesn't exist yet)."
  fi
fi
exit 0
