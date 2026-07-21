# Containerized workspace for the three agent CLIs (Claude Code, GitHub
# Copilot CLI, Pi), each its own final stage so `docker compose run <tool>`
# only ships what that tool needs. All three share the `base` stage's
# toolchain (mirrors nix/packages.nix: node, git, ripgrep, jq, python3, a
# build toolchain for native npm modules and dotnet-less C# gates).
#
# Config (hooks, skills, AGENTS.md, the pi sandbox extension) is baked into
# /opt/agent-config/ here, then synced into the tool's real config dir by
# entrypoint.sh on every container start — not COPY'd straight into
# ~/.claude etc, because a named volume mounted over that path on first run
# would freeze whatever was there at that moment. Syncing on every start
# means rebuilding the image (updated hooks) always takes effect on the next
# `docker compose run`, while auth.json/trust.json/session history in the
# volume survive untouched (entrypoint.sh never touches those paths).
FROM node:22-bookworm-slim AS base

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash git ripgrep jq curl ca-certificates python3 build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash agent
# A named volume mounted at a path with nothing there yet is created
# root-owned; pre-creating these (agent-owned) so each stage's credential
# volume — .claude, .copilot, or .pi — inherits the right ownership on its
# first mount instead of leaving entrypoint.sh's mkdir/cp calls EACCES.
RUN mkdir -p /home/agent/.claude /home/agent/.copilot /home/agent/.pi \
    && chown -R agent:agent /home/agent
USER agent
ENV HOME=/home/agent
WORKDIR /workspace

COPY --chown=agent:agent agents/AGENTS.md /opt/agent-config/agents/AGENTS.md
COPY --chown=agent:agent agents/skills /opt/agent-config/agents/skills
# boilerplats ships to every stage: all three tools run boilerplate-guard.sh
# (Claude via settings.json, Copilot via pre-tool-use.sh, Pi via index.ts),
# which hard-blocks hand-written boilerplate and directs the model to
# ~/.agents/boilerplats/scaffold.js. Without the generator here that block is a
# dead end with no way out. node_modules/ is gitignored so it never arrives via
# COPY; baking `npm ci` in at build time (rather than leaving it to the
# ~/.cache/boilerplats fallback nix/agents.nix populates) means scaffold.js's
# plain `require('handlebars')` resolves from its own directory and containers
# never need the registry at run time.
COPY --chown=agent:agent agents/boilerplats /opt/agent-config/agents/boilerplats
COPY --chown=agent:agent docker/entrypoint.sh /opt/agent-config/entrypoint.sh
USER root
# npm_config_cache is redirected because this RUN is root while HOME is still
# the agent user's — the default cache would leave root-owned files in
# /home/agent/.npm that later agent-user npm calls can't write through.
RUN chmod +x /opt/agent-config/entrypoint.sh \
    && npm_config_cache=/tmp/npm-cache \
       npm ci --prefix /opt/agent-config/agents/boilerplats --no-fund --no-audit \
    && rm -rf /tmp/npm-cache
USER agent

# ---- claude ----
FROM base AS claude
USER root
# Run as `root` for full permissions inside the container. The installer's
# own `claude install` step will put the binary in root's $HOME/.local/bin.
ENV HOME=/root
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
# Claude Code refuses --dangerously-skip-permissions as root/sudo unless it
# knows it's already sandboxed (undocumented escape hatch, confirmed via
# anthropics/claude-code#9184) — true here since the container itself is the
# sandbox and only /workspace is mounted in.
ENV IS_SANDBOX=1
COPY --chown=root:root claude/hooks /opt/agent-config/claude/hooks
COPY --chown=root:root claude/statusline-usage.py /opt/agent-config/claude/statusline-usage.py
# settings.json ships verbatim. It used to be filtered through a `jq del(...)`
# that stripped hooks pointing at a live host checkout (~/REPO/scaffold-toolkit)
# which isn't mounted here. Those hooks are long gone, but the filter selected
# them by array index, so as settings.json changed the indices silently came to
# name different entries — by the time it was caught it was deleting
# context-augment.py and boilerplate-guard.sh instead. Every hook now in
# settings.json points into ~/.claude/hooks, which entrypoint.sh populates for
# every AGENT_TOOL, so nothing needs stripping. If that changes again, filter by
# matching .command, never by index.
COPY --chown=root:root claude/settings.json /opt/agent-config/claude/settings.json
ENV AGENT_TOOL=claude
ENTRYPOINT ["/opt/agent-config/entrypoint.sh"]
CMD ["claude"]

# ---- copilot ----
FROM base AS copilot
USER root
# Run as `root` for full permissions inside the container.
ENV HOME=/root
RUN npm install --global @github/copilot \
    && chown -R root:root /root/.npm 2>/dev/null || true
COPY --chown=root:root copilot/hooks/lib /opt/agent-config/copilot/hooks/lib
COPY --chown=root:root copilot/hooks/mohan-hooks.json /opt/agent-config/copilot/hooks/mohan-hooks.json
# Every script mohan-hooks.json registers must be listed here, or Copilot fails
# that hook on each fire. Enforced by the docker-hook-parity flake check.
COPY --chown=root:root copilot/hooks/session-start.sh copilot/hooks/user-prompt-submit.sh \
     copilot/hooks/user-prompt-submit-context.sh copilot/hooks/pre-tool-use.sh \
     copilot/hooks/post-tool-use.sh copilot/hooks/agent-stop.sh \
     copilot/hooks/pre-compact.sh \
     copilot/hooks/session-end-cleanup.sh copilot/hooks/session-end-audit.sh \
     /opt/agent-config/copilot/hooks/
# copilot/hooks reuses claude/hooks scripts via CLAUDE_HOOKS_HOME (see
# copilot/hooks/lib/common.sh) — those need to exist here too, independent
# of whether the claude stage is ever built.
COPY --chown=root:root claude/hooks /opt/agent-config/claude/hooks
ENV AGENT_TOOL=copilot
ENTRYPOINT ["/opt/agent-config/entrypoint.sh"]
CMD ["copilot"]

# ---- pi ----
FROM base AS pi
USER root
# Run as `root` for full permissions inside the container.
ENV HOME=/root
RUN npm install --global --ignore-scripts @earendil-works/pi-coding-agent \
    && chown -R root:root /root/.npm 2>/dev/null || true
COPY --chown=root:root pi/agent/extensions/hooks /opt/agent-config/pi/extensions/hooks
COPY --chown=root:root pi/agent/extensions/sandbox /opt/agent-config/pi/extensions/sandbox
# claude/hooks reused by pi/agent/extensions/hooks/lib.ts (see its
# runClaudeHook helper), same cross-reference as the copilot stage above.
COPY --chown=root:root claude/hooks /opt/agent-config/claude/hooks
# Bake the sandbox extension's npm deps at build time so entrypoint.sh only
# has to copy a directory, not run npm install (and therefore need network)
# on every container start.
RUN npm install --prefix /opt/agent-config/pi/extensions/sandbox
ENV AGENT_TOOL=pi
ENTRYPOINT ["/opt/agent-config/entrypoint.sh"]
CMD ["pi"]
