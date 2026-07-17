# Wrapper for docker/docker-compose.yml: runs Claude Code, Copilot CLI, or
# Pi fully containerized against whatever repo you're currently in, so
# nothing the agent does touches this machine outside that mount. --build
# keeps the image (hooks, skills, settings) current automatically; it's a
# fast no-op once the layer cache is warm.
_agent_box_compose="$HOME/REPO/mohan-dotfiles/docker/docker-compose.yml"

agent-box() {
  if [ $# -lt 1 ]; then
    echo "usage: agent-box <claude|copilot|pi> [args...]" >&2
    return 2
  fi
  local tool="$1"
  shift
  REPO_PATH="$PWD" docker compose -f "$_agent_box_compose" run --rm --build "$tool" "$@"
}

alias claude-box='agent-box claude'
alias copilot-box='agent-box copilot'
alias pi-box='agent-box pi'
