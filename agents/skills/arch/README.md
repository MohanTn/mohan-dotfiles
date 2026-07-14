# arch: shared template + injection script

The common layer behind Claude Code's `/arch` command (`claude/commands/arch.md`) and Copilot CLI's `arch` skill (`copilot/skills/arch/SKILL.md`): one HTML template and one Node.js injection script, no tool-specific content, deployed once to `~/.agents/skills/arch/` (see `nix/agents.nix`) and referenced by both tools at that fixed path. Neither `claude/` nor `copilot/` keeps its own copy.

## What the document is for

`/arch` produces an **architecture & solution plan** as a working document, not a passive spec. The AI drafts the plan's structure (project overview, actors, containers, integrations, data model, ADRs, quality attributes, security, deployment, risks, roadmap) and seeds an editable HTML page. The human then edits every section, adding or removing items, refining prose, recording decisions, and exports the result as plain text via **Copy plan as text**. Everything is editable in-browser and persists per document via `localStorage` (key derived from `document.title`, so different `arch-<slug>.html` files don't share state).

The on-page sections in order:

- **Project Overview** — name, brief description, and business background.
- **System Context** — actors and external systems that interact with the solution (with type: User / External System / Internal System).
- **Containers / Services** — deployable units (web apps, APIs, workers), each with tech stack, responsibilities, and data stores.
- **Integrations & Data Flows** — connections between components (with protocol + sync/async).
- **Data Model** — core entities, attributes/schema, relationships, and storage tech.
- **Architectural Decisions (ADRs)** — context, decision, rationale, trade-offs, status.
- **Quality Attributes** — non-functional requirements (availability, performance, etc.) with targets and measurement methods.
- **Security & Compliance** — authn/authz, encryption, standards.
- **Deployment & Infrastructure** — cloud, regions, sizing, scaling.
- **Risks & Mitigations** — with impact, probability, and mitigation.
- **Implementation Roadmap** — phases with deliverables and timeline.

The **Export & Governance** card adds a **Copy plan as text** button (full document as plain text, ready to paste back) and a **Reset all data** button.

## Two-stage workflow

1. **Content (the AI).** Generates the plan as **structured JSON** — `title`, `description`, `context`, and `actors` / `containers` / `integrations` / `entities` / `adrs` / `qualities` / `security` / `deployment` / `risks` / `roadmap`. Cheap in tokens: no template boilerplate is regenerated.
2. **Injection (the script).** `arch-inject.js` merges that JSON into `arch-template.html` deterministically, embedding it as the page's `INITIAL_DATA`. The AI never reads or rewrites the template.

## Usage

```bash
# First draft
/arch e-commerce platform

# Refinement: open the file, edit any section directly in the browser, click
# "Copy plan as text", paste the block back so the AI can implement.
```

Manual injection (either tool, same path):

```bash
node ~/.agents/skills/arch/arch-inject.js arch-plan.json arch-plan.html
# The third (template-path) argument is optional; it defaults to
# arch-template.html next to the script, so this also works from a checkout:
node agents/skills/arch/arch-inject.js arch-plan.json arch-plan.html
```

## JSON structure

Top-level keys: `title` (→ Project Name), `description` (→ Brief Description), `context` (→ Background). Section arrays mirror the on-page cards 1:1.

```json
{
  "title": "E-commerce Platform",
  "description": "Multi-tenant storefront with checkout, payments, and fulfilment.",
  "context": "Replaces the legacy monolith with a service-oriented platform.",
  "actors": [
    { "id": "a1", "name": "Customer", "type": "User", "description": "Browses and checks out" },
    { "id": "a2", "name": "Payment Gateway", "type": "External System", "description": "Stripe" }
  ],
  "containers": [
    { "id": "c1", "name": "Storefront API", "tech": "Node.js", "responsibilities": "Product, cart, checkout", "dataStores": "ProductDB" }
  ],
  "integrations": [
    { "id": "i1", "name": "Checkout sync", "from": "Storefront", "to": "Payment Gateway", "protocol": "REST", "sync": "Sync", "description": "create charge" }
  ],
  "entities": [
    { "id": "e1", "name": "Order", "attributes": "id, userId, total", "relationships": "belongs to User", "storage": "PostgreSQL" }
  ],
  "adrs": [
    { "id": "d1", "name": "Use PostgreSQL", "context": "Need transactional guarantees", "decision": "PostgreSQL 16", "rationale": "mature, ACID", "tradeoffs": "ops overhead", "status": "Accepted" }
  ],
  "qualities": [
    { "id": "q1", "name": "Availability", "target": "99.95%", "measurement": "Prometheus uptime", "details": "Multi-AZ" }
  ],
  "security": [
    { "id": "s1", "name": "OAuth2 for APIs", "detail": "JWT with rotating keys" }
  ],
  "deployment": [
    { "id": "dp1", "name": "Cloud", "detail": "AWS, multi-region primary/secondary" }
  ],
  "risks": [
    { "id": "r1", "name": "Payment gateway downtime", "impact": "High", "probability": "Low", "mitigation": "Queue + retry with circuit breaker" }
  ],
  "roadmap": [
    { "id": "p1", "name": "Phase 1: MVP", "features": "Storefront + payments", "timeline": "Q3 2026" }
  ]
}
```

Allowed select values: `actors.type` ∈ { User, External System, Internal System }, `integrations.protocol` ∈ { REST, gRPC, GraphQL, WebSocket, Message Queue, Event Bus, File Transfer }, `integrations.sync` ∈ { Sync, Async }, `adrs.status` ∈ { Proposed, Accepted, Deprecated, Superseded }. The script fills in defaults for any missing field, so a sparse input still renders a valid page.

`id` fields just need to be unique strings; any scheme works. The inject script preserves `id` so the user's existing in-browser edits stay linked to the right item across re-injections.

## Files

- **arch-template.html** — the template with `{{PROJECT_TITLE}}` (for `<title>` and `<h1>`) and `{{INITIAL_DATA_JSON}}` markers. Renders every section entirely client-side from the injected data object. Uses `localStorage` key `'arch-plan:' + document.title` so each `arch-<slug>.html` keeps its own state.
- **arch-inject.js** — reads JSON, escapes the title, and embeds the rest of the plan as a JSON literal (`INITIAL_DATA`) inside a `<script>` tag, escaping `</script>` breakout and the U+2028/U+2029 line-terminator characters that `JSON.stringify` leaves raw. `normalizePlan` maps friendly top-level keys (`title`, `description`, `context`) to template field names (`projectName`, `projectDesc`, `projectContext`), and applies per-section defaults via a single `ITEM_FIELD_DEFAULTS` table. Template path is optional.
- **arch-inject.test.js** — unit tests for the injection script and template contract. Run with `node --test agents/skills/arch/arch-inject.test.js`. Covers escaping, script-breakout/line-terminator safety, default-filling for both top-level and per-section fields, and placeholder completeness.

The instruction files that drive generation stay in each tool's directory (`claude/commands/arch.md`, `copilot/skills/arch/SKILL.md`): they're prose, not shared boilerplate, and differ in voice and path references. Both point at this folder's script and template by the same fixed `~/.agents/skills/arch/` path.

## Extending

To add a new section: add its field schema to `arch-template.html`'s render layer with the matching HTML container + add button + `bindAddButton` call, then `ITEM_FIELD_DEFAULTS` and the section key in `arch-inject.js`'s `SECTIONS`/`ITEM_FIELD_DEFAULTS`, plus a test. Finally, document the new JSON key in **both** `claude/commands/arch.md` and `copilot/skills/arch/SKILL.md` (they aren't shared). The AI's next generation picks up the new format.
