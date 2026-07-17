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
COPY --chown=agent:agent docker/entrypoint.sh /opt/agent-config/entrypoint.sh
USER root
RUN chmod +x /opt/agent-config/entrypoint.sh
USER agent

# ---- claude ----
FROM base AS claude
# Run as `agent`, not root: the installer's own `claude install` step puts
# the binary at $HOME/.local/bin/claude, matching claude.nix's host-side
# bootstrap check. Its install.sh only takes an optional stable/latest/
# VERSION positional arg, not a --install-dir flag.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/agent/.local/bin:${PATH}"
COPY --chown=agent:agent claude/hooks /opt/agent-config/claude/hooks
COPY --chown=agent:agent claude/statusline-usage.py /opt/agent-config/claude/statusline-usage.py
# scaffold-toolkit hooks reference a live host checkout (~/REPO/scaffold-toolkit)
# that isn't mounted into the container, so they're stripped rather than
# copied verbatim — Claude Code hooks fail open on a missing script (shown
# to the user as a non-blocking error, not a deny), but there's no reason to
# ship a hook that can only ever error in this environment. RUN executes
# against the image filesystem, not the build context, so the source file
# has to be COPY'd in before jq can read it.
COPY --chown=agent:agent claude/settings.json /tmp/claude-settings.json
RUN jq 'del(.hooks.UserPromptSubmit[1], .hooks.PreToolUse[0].hooks[0], .hooks.PostToolUse[1], .hooks.Stop[1])' \
    /tmp/claude-settings.json > /opt/agent-config/claude/settings.json \
    && rm /tmp/claude-settings.json
USER agent
ENV AGENT_TOOL=claude
ENTRYPOINT ["/opt/agent-config/entrypoint.sh"]
CMD ["claude"]

# ---- copilot ----
FROM base AS copilot
USER root
# HOME stays /home/agent across the USER switch (ENV isn't user-scoped in
# Docker), so an npm install run as root here writes a root-owned cache
# under the agent user's home — chown it back or any later npm invocation
# as `agent` (in this stage or a future change) fails with EACCES on it,
# same bug the pi stage's own extra `npm install --prefix ...` step hit.
RUN npm install --global @github/copilot \
    && chown -R agent:agent /home/agent/.npm 2>/dev/null || true
COPY --chown=agent:agent copilot/hooks/lib /opt/agent-config/copilot/hooks/lib
COPY --chown=agent:agent copilot/hooks/mohan-hooks.json /opt/agent-config/copilot/hooks/mohan-hooks.json
COPY --chown=agent:agent copilot/hooks/session-start.sh copilot/hooks/user-prompt-submit.sh \
     copilot/hooks/pre-tool-use.sh copilot/hooks/post-tool-use.sh copilot/hooks/agent-stop.sh \
     copilot/hooks/session-end-cleanup.sh /opt/agent-config/copilot/hooks/
# copilot/hooks reuses claude/hooks scripts via CLAUDE_HOOKS_HOME (see
# copilot/hooks/lib/common.sh) — those need to exist here too, independent
# of whether the claude stage is ever built.
COPY --chown=agent:agent claude/hooks /opt/agent-config/claude/hooks
USER agent
ENV AGENT_TOOL=copilot
ENTRYPOINT ["/opt/agent-config/entrypoint.sh"]
CMD ["copilot"]

# ---- pi ----
FROM base AS pi
USER root
# Same root-writes-into-agent's-$HOME cache issue as the copilot stage; here
# it's not just latent — the later `npm install --prefix` as `agent` in this
# same stage genuinely fails EACCES on the root-owned cache without this.
RUN npm install --global --ignore-scripts @earendil-works/pi-coding-agent \
    && chown -R agent:agent /home/agent/.npm 2>/dev/null || true
COPY --chown=agent:agent pi/agent/extensions/hooks /opt/agent-config/pi/extensions/hooks
COPY --chown=agent:agent pi/agent/extensions/sandbox /opt/agent-config/pi/extensions/sandbox
# claude/hooks reused by pi/agent/extensions/hooks/lib.ts (see its
# runClaudeHook helper), same cross-reference as the copilot stage above.
COPY --chown=agent:agent claude/hooks /opt/agent-config/claude/hooks
USER agent
# Bake the sandbox extension's npm deps at build time so entrypoint.sh only
# has to copy a directory, not run npm install (and therefore need network)
# on every container start.
RUN npm install --prefix /opt/agent-config/pi/extensions/sandbox
ENV AGENT_TOOL=pi
ENTRYPOINT ["/opt/agent-config/entrypoint.sh"]
CMD ["pi"]
