{ ... }:

{
  # The common layer shared between Claude Code and Copilot CLI: utility
  # scripts and templates with no tool-specific content (currently /arch
  # and /featurePlan — each is an HTML template + a Node.js injection
  # script + a unit test). Deployed once to ~/.agents; claude/commands/
  # <name>.md and copilot/skills/<name>/SKILL.md each reference their own
  # fixed path under this directory instead of each keeping its own copy.
  # Whole-directory link is safe here because ~/.agents is not shared with
  # any other home.file target (unlike ~/.claude or ~/.copilot, which
  # already own their whole subtrees).
  home.file.".agents".source = ../agents;
}
