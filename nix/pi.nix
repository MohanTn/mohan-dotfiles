{ pkgs, lib, ... }:

{
  # Global instructions: same content as claude/CLAUDE.md's `@~/.agents/AGENTS.md`
  # import and copilot.nix's copilot-instructions.md, rendered at build time
  # since Pi's own instructions path (~/.pi/agent/AGENTS.md) has no confirmed
  # @import directive the way Claude Code does.
  home.file.".pi/agent/AGENTS.md".text = builtins.readFile ../agents/AGENTS.md;

  # Boilerplate-generator hint (see agents/boilerplats/AGENT-HINT.md): on
  # Claude Code it's a keyword-gated UserPromptSubmit hook
  # (claude/hooks/boilerplate-hint.sh) and on Copilot it's appended to
  # session-start.sh's once-per-session additionalContext, since neither of
  # Pi's own per-turn hook events can rewrite the system prompt outside an
  # extension. APPEND_SYSTEM.md is Pi's native, documented mechanism for a
  # permanent system-prompt addition (docs/usage.md's "System Prompt Files"),
  # so it's used directly here instead of porting the hook logic — it's
  # always present, including after context compaction, unlike an injected
  # session message.
  home.file.".pi/agent/APPEND_SYSTEM.md".text =
    builtins.readFile ../agents/boilerplats/AGENT-HINT.md;

  # TypeScript port of claude/hooks (see pi/agent/extensions/hooks/index.ts for
  # the event-mapping rationale). Pure node:* built-ins, no npm deps, so a
  # plain read-only store symlink is enough — same role as .claude/hooks.
  home.file.".pi/agent/extensions/hooks".source = ../pi/agent/extensions/hooks;

  # Skills: agents/skills/ is already linked to ~/.agents by agents.nix, and
  # Pi natively auto-discovers ~/.agents/skills/*/SKILL.md (confirmed against
  # docs/skills.md) — no separate wiring needed here, unlike claude.nix and
  # copilot.nix which each link agents/skills into a tool-specific path.

  # The sandbox extension (Pi's own examples/extensions/sandbox, vendored into
  # pi/agent/extensions/sandbox) needs `npm install` for @anthropic-ai/sandbox-runtime,
  # so unlike hooks/ it can't be a read-only store symlink — home.file copies
  # its two source files into a normal writable directory instead, which
  # installPi below then `npm install`s into.
  home.activation.piSandboxExtensionFiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    dst="$HOME/.pi/agent/extensions/sandbox"
    run mkdir -p "$dst"
    run install -m 0644 ${../pi/agent/extensions/sandbox/index.ts} "$dst/index.ts"
    run install -m 0644 ${../pi/agent/extensions/sandbox/package.json} "$dst/package.json"
  '';

  # Pi stays on its native npm-based installer so it keeps self-updating via
  # `pi update self`, matching how Claude Code and Copilot CLI are bootstrapped
  # only when missing (see claude.nix, optional-packages.nix). Must run after
  # piSandboxExtensionFiles explicitly, not just "installPackages" — both
  # being entryAfter'd off writeBoundary-descended nodes does not itself
  # order them relative to each other; without this, home-manager was free
  # to (and did) run this before piSandboxExtensionFiles had copied
  # package.json into place, so `npm install --prefix` failed with ENOENT.
  home.activation.installPi = lib.hm.dag.entryAfter [ "installPackages" "piSandboxExtensionFiles" ] ''
    export PATH="${pkgs.nodejs_22}/bin:$PATH"
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"

    if ! command -v pi >/dev/null 2>&1; then
      echo "Installing Pi coding agent..."
      $DRY_RUN_CMD npm install --global --ignore-scripts @earendil-works/pi-coding-agent
    fi

    if [ ! -d "$HOME/.pi/agent/extensions/sandbox/node_modules" ]; then
      echo "Installing pi sandbox extension dependencies..."
      $DRY_RUN_CMD npm install --prefix "$HOME/.pi/agent/extensions/sandbox"
    fi
  '';
}
