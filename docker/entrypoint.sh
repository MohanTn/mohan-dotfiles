#!/bin/bash
# Runs on every container start (before the tool's own CMD), keyed by the
# AGENT_TOOL env var each Dockerfile stage sets. Syncs baked config from
# /opt/agent-config/ into the tool's real config dir under $HOME — never a
# one-time COPY at build time, because $HOME is backed by a named volume
# that persists auth.json/trust.json/session history across runs, and a
# volume mounted over a path only inherits the image's content on its very
# first mount. Re-syncing here means a rebuilt image's hooks/settings always
# take effect on the next `docker compose run`, without ever touching the
# credential/session files this script doesn't mention.
#
# copilot/hooks and pi/agent/extensions/hooks both shell out to
# claude/hooks/*.sh (see copilot/hooks/lib/common.sh's CLAUDE_HOOKS_HOME and
# pi/agent/extensions/hooks/lib.ts's runClaudeHook), so ~/.claude/hooks is
# synced for every AGENT_TOOL, not just "claude".
set -euo pipefail

mkdir -p "$HOME/.claude"
rm -rf "$HOME/.claude/hooks"
cp -r /opt/agent-config/claude/hooks "$HOME/.claude/hooks"

sync_agents_layer() {
  mkdir -p "$HOME/.agents"
  cp -f /opt/agent-config/agents/AGENTS.md "$HOME/.agents/AGENTS.md"
  rm -rf "$HOME/.agents/skills"
  cp -r /opt/agent-config/agents/skills "$HOME/.agents/skills"
}

case "${AGENT_TOOL:-}" in
  claude)
    # claude-agent-home mounts all of /root, so a volume created before this
    # image installed claude to /root/.local/bin (or from an older
    # Dockerfile) never gets the binary — named volumes only inherit image
    # content on their very first mount. Self-heal instead of failing at
    # `exec "$@"`.
    if ! command -v claude >/dev/null 2>&1; then
      echo "entrypoint.sh: claude binary missing (stale volume), reinstalling..." >&2
      curl -fsSL https://claude.ai/install.sh | bash
    fi
    sync_agents_layer
    printf '@~/.agents/AGENTS.md\n' > "$HOME/.claude/CLAUDE.md"
    cp -f /opt/agent-config/claude/settings.json "$HOME/.claude/settings.json"
    cp -f /opt/agent-config/claude/statusline-usage.py "$HOME/.claude/statusline-usage.py"
    rm -rf "$HOME/.claude/skills"
    cp -r /opt/agent-config/agents/skills "$HOME/.claude/skills"
    ;;
  copilot)
    mkdir -p "$HOME/.copilot/skills"
    cp -f /opt/agent-config/agents/AGENTS.md "$HOME/.copilot/copilot-instructions.md"
    rm -rf "$HOME/.copilot/hooks"
    cp -r /opt/agent-config/copilot/hooks "$HOME/.copilot/hooks"
    # Only scaffold-pack-author, matching nix/copilot.nix: Copilot can't
    # render the Claude-artifact-specific skills (arch, featurePlan).
    rm -rf "$HOME/.copilot/skills/scaffold-pack-author"
    cp -r /opt/agent-config/agents/skills/scaffold-pack-author "$HOME/.copilot/skills/scaffold-pack-author"
    ;;
  pi)
    sync_agents_layer
    mkdir -p "$HOME/.pi/agent/extensions"
    cp -f /opt/agent-config/agents/AGENTS.md "$HOME/.pi/agent/AGENTS.md"
    rm -rf "$HOME/.pi/agent/extensions/hooks"
    cp -r /opt/agent-config/pi/extensions/hooks "$HOME/.pi/agent/extensions/hooks"
    rm -rf "$HOME/.pi/agent/extensions/sandbox"
    cp -r /opt/agent-config/pi/extensions/sandbox "$HOME/.pi/agent/extensions/sandbox"
    ;;
  *)
    echo "entrypoint.sh: unknown or unset AGENT_TOOL '${AGENT_TOOL:-}'" >&2
    exit 1
    ;;
esac

exec "$@"
