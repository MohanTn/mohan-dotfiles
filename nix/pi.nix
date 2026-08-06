{ pkgs, lib, ... }:

{
  # No permissions/settings.json porting needed here: Pi has no default
  # tool-confirmation prompt at all (docs/security.md - built-in tools run
  # with the pi process's full permissions unless an extension adds a gate),
  # so claude/settings.json's permissions.allow (Bash(rg *), Bash(git diff *))
  # has nothing to mirror. See nix/zsh.nix's `copilot` alias for the Copilot
  # CLI counterpart, which does need one.

  # Global instructions: same content as claude/CLAUDE.md's `@~/.agents/AGENTS.md`
  # import and copilot.nix's copilot-instructions.md, rendered at build time
  # since Pi's own instructions path (~/.pi/agent/AGENTS.md) has no confirmed
  # @import directive the way Claude Code does.
  home.file.".pi/agent/AGENTS.md".text = builtins.readFile ../agents/AGENTS.md;

  # System prompt: SYSTEM.md replaces Pi's default coding-assistant prompt
  # (docs/usage.md, "System Prompt Files"), the same lean prompt the `cc` alias
  # feeds Claude Code via --system-prompt-file (nix/zsh.nix). It is written
  # harness-neutral, so it names no tool only one of them has.
  home.file.".pi/agent/SYSTEM.md".text = builtins.readFile ../agents/lean-system-prompt.md;

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

  # Scaffold MCP server: none here by design. Pi ships no MCP client at all —
  # docs/usage.md states it "intentionally does not include built-in MCP,
  # sub-agents, permission popups, plan mode, to-dos, or background bash", so
  # on Pi the scaffold path stays the CLI (`scaffold.js --json`, same
  # engine and structured output as the MCP tools) via the APPEND_SYSTEM.md
  # hint above, and the write-around guards run through hooks/index.ts's
  # bash-write-guard.sh + boilerplate-guard.sh calls — policy parity with
  # Claude/Copilot even without the MCP transport.

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
    run install -m 0644 ${../pi/agent/extensions/sandbox/trusted-commands.ts} "$dst/trusted-commands.ts"
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
