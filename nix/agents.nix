{ ... }:

{
  # The common layer shared between Claude Code and Copilot CLI: utility
  # scripts and templates with no tool-specific content (currently just
  # /arch's HTML template and its Node.js injection script + test). Deployed
  # once to ~/.agents; claude/commands/arch.md and copilot/skills/arch/SKILL.md
  # both reference this one fixed path instead of each keeping their own
  # copy. Whole-directory link is safe here because ~/.agents is not shared
  # with any other home.file target (unlike ~/.claude or ~/.copilot, which
  # already own their whole subtrees).
  home.file.".agents".source = ../agents;
}
