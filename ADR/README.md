# Architecture Decision Records (ADRs)

Short documents that capture a non-obvious dotfiles decision along with its
context and consequences, so the reasoning survives even when the diff alone
would not explain it. Reserve these for choices future-me would otherwise have
to re-derive from scratch (a hook policy, a port-parity rule, a tool
boundary) — not every commit needs one.

## Format

```
# ADR-NNNN: Title

- **Status:** Proposed | Accepted | Deprecated | Superseded by ADR-XXXX
- **Date:** YYYY-MM-DD

## Context

What prompted this decision?

## Decision

What was decided?

## Consequences

What gets easier or harder because of it?
```

## Naming

`NNNN-short-title.md`, numbers zero-padded to 4 digits, kebab-case title.
ADRs are immutable once accepted — a reversed decision gets a new ADR that
supersedes the old one, not an edit to it.

## Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001](0001-use-adr-for-decisions.md) | Use ADRs for dotfiles decisions | Accepted | 2026-07-30 |
