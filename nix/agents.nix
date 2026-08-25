{ pkgs, lib, ... }:

{
  # The tool-agnostic agents layer: AGENTS.md (global instructions,
  # referenced by claude/CLAUDE.md) and skills/ (also linked to
  # ~/.claude/skills by claude.nix so Claude Code discovers them).
  # Whole-directory link is safe here because ~/.agents is not shared with
  # any other home.file target (unlike ~/.claude, which already owns its
  # whole subtree).
  home.file.".agents".source = ../agents;
}
