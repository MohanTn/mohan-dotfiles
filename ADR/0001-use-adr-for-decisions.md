# ADR-0001: Use ADRs for Dotfiles Decisions

- **Status:** Accepted
- **Date:** 2026-07-30

## Context

This repo carries real architectural rules (the hook port-parity rule between
`claude/hooks`, `copilot/hooks`, and `pi/agent/extensions/hooks`; the
boilerplate-mandate vs. bake-time/invoke-time guard split; the `agents/` vs.
tool-specific-directory boundary). Today those rules live only in prose
scattered across `AGENTS.md` and file-header comments. That's fine for the
current rule, but nothing records *why* a past alternative was rejected, so a
future change can silently re-break a constraint whose reasoning was never
written down anywhere durable.

## Decision

Adopt lightweight Architecture Decision Records under `/ADR` for decisions
about this repo's own structure and hook/skill policy, not for every commit.
Write one when a change establishes or reverses a rule that isn't obvious
from the diff alone, mirroring the practice observed in `agentoven` (a
separate project this repo's agent setup was benchmarked against).

## Consequences

- **Easier:** the next change to a hook/port rule can check whether it
  contradicts a past decision instead of re-deriving the tradeoff from
  scratch.
- **Harder:** a small amount of extra discipline, writing an ADR before or
  alongside a structural change instead of only a commit message.
