---
name: arch
description: Take a system or project the user has in mind and turn it into an architecture & solution plan (arch-<slug>.html) — a working, editable document covering project overview, system context, containers, integrations, data model, ADRs, quality attributes, security, deployment, risks, and roadmap, all grounded in the actual repo. Use when the user asks for an architecture plan, solution design, system overview, or says "arch".
---

# arch: Architecture & solution plan via JSON → HTML injection

Take a system or project the user has in mind and turn it into a **working architecture & solution plan**. You generate structured JSON; a deterministic script (`arch-inject.js`) injects it into the HTML template — you never rewrite the template. The user edits each section in the browser, then clicks **Copy plan as text** and pastes the result back so the AI can implement or refine.

**Prime directive:** every section gets a real, grounded draft pulled from the actual code or requirements — not vague filler. If a section truly has nothing to seed (e.g. no compliance scope yet), leave it empty rather than fabricate.

---

## Operating modes

**Mode A — First draft.** No `arch-<slug>.html` in the working directory.
1. Research the repo (see below). Draft each section with real content from the actual code: actors touching this system, existing/needed containers and stack choices, integrations, data model, ADRs grounded in the codebase, quality attributes with measurable targets, security stance, deployment topolography, known risks, phased roadmap.
2. Assemble JSON, save to `arch-<slug>.json` (temporary).
3. Run `node ~/.agents/skills/arch/arch-inject.js arch-<slug>.json arch-<slug>.html`.
4. Delete the temporary JSON.

**Mode B — Refinement pass.** `arch-<slug>.html` exists and the user pastes the doc's **"Copy plan as text"** block. The block contains the full exported document — project metadata, each section's items, no decisions to make (ADRs already have status, no "(select one)" prompts) — so go straight to implementing, or update sections and re-inject if scope shifted.

**Derive `<slug>`** from the project or system the user named: a few words, lowercased, spaces→hyphens (e.g. "billing retry logic" → `billing-retry-logic`). Use `arch-<slug>.html` as the file name.

---

## Before generating (research, don't guess)

- Read the actual code, configs, and infra definitions the architecture touches before drafting any section — actors/containers/integrations should reference real components, real storage tech, real protocols in use, not generically named ones.
- Never do web research; ground options in this repo.

---

## Top-level (`title`, `description`, `context`)

- `title` — short project name; goes into `<title>`, `<h1>`, and the Project Overview card. Keep it slug-friendly (no slashes / colons).
- `description` — one-sentence "what & for whom" pitch; appears in the Project Overview card.
- `context` — business drivers, existing-system notes, key constraints; free text in the Project Overview card.

---

## Sections (`actors`, `containers`, `integrations`, `entities`, `adrs`, `qualities`, `security`, `deployment`, `risks`, `roadmap`)

Each section is an array of items. Item shape per section:

- **actors** — `{ id, name, type, description }`. `type` must be one of `User`, `External System`, `Internal System`.
- **containers** — `{ id, name, tech, responsibilities, dataStores }`. `tech` is the stack (e.g. "Node.js", ".NET 8", "Postgres"); `dataStores` lists each store this container owns.
- **integrations** — `{ id, name, from, to, protocol, sync, description }`. `protocol` ∈ { REST, gRPC, GraphQL, WebSocket, Message Queue, Event Bus, File Transfer }; `sync` ∈ { Sync, Async }.
- **entities** — `{ id, name, attributes, relationships, storage }`. `attributes` is a sketched schema (e.g. `id, userId, total`); `storage` is the tech that stores it.
- **adrs** — `{ id, name, context, decision, rationale, tradeoffs, status }`. `status` ∈ { Proposed, Accepted, Deprecated, Superseded }; mark each ADR Proposed unless the codebase already implements it (then Accepted).
- **qualities** — `{ id, name, target, measurement, details }`. `target` is concrete (a number + unit), e.g. `99.95%`, `< 200 ms p95`. `measurement` is how you'll observe it (Prometheus metric, load test, etc.).
- **security** — `{ id, name, detail }`. One item per concern (auth, transport, secrets, audit, compliance).
- **deployment** — `{ id, name, detail }`. Cloud, regions, sizing, scaling, DR — one item per topic.
- **risks** — `{ id, name, impact, probability, mitigation }`. `impact` / `probability` are free text ("High"/"Medium"/"Low" or a one-liner); `mitigation` explains the countermeasure.
- **roadmap** — `{ id, name, features, timeline }`. One per phase; `features` can be a multi-line summary.

---

## JSON Output Format

Write this to `arch-<slug>.json`:

```json
{
  "title": "Project / system name",
  "description": "One-sentence pitch",
  "context": "Business drivers, existing systems, constraints…",
  "actors": [
    { "id": "actor-1", "name": "Customer", "type": "User", "description": "Browses and checks out" },
    { "id": "actor-2", "name": "Payment Gateway", "type": "External System", "description": "Stripe" }
  ],
  "containers": [
    { "id": "c-1", "name": "Storefront API", "tech": "Node.js", "responsibilities": "Product, cart, checkout", "dataStores": "ProductDB" }
  ],
  "integrations": [
    { "id": "i-1", "name": "Checkout sync", "from": "Storefront", "to": "Payment Gateway", "protocol": "REST", "sync": "Sync", "description": "create charge" }
  ],
  "entities": [
    { "id": "e-1", "name": "Order", "attributes": "id, userId, total", "relationships": "belongs to User", "storage": "PostgreSQL" }
  ],
  "adrs": [
    { "id": "a-1", "name": "ADR-001: Use PostgreSQL", "context": "Need transaction guarantees", "decision": "PostgreSQL 16", "rationale": "Mature, ACID", "tradeoffs": "Operational overhead", "status": "Accepted" }
  ],
  "qualities": [
    { "id": "q-1", "name": "Availability", "target": "99.95%", "measurement": "Prometheus uptime", "details": "Multi-AZ" }
  ],
  "security": [
    { "id": "s-1", "name": "OAuth2 for APIs", "detail": "JWT with rotating keys" }
  ],
  "deployment": [
    { "id": "d-1", "name": "Cloud", "detail": "AWS, multi-region primary/secondary" }
  ],
  "risks": [
    { "id": "r-1", "name": "Payment gateway downtime", "impact": "High", "probability": "Low", "mitigation": "Queue + retry with circuit breaker" }
  ],
  "roadmap": [
    { "id": "p-1", "name": "Phase 1: MVP", "features": "Storefront + payments", "timeline": "Q3 2026" }
  ]
}
```

`id` fields just need to be unique strings; any scheme works.

---

## After saving

Print to chat:
1. Filename (`arch-<slug>.html`).
2. One line per non-empty section so the user knows what was drafted (e.g. "actors: 2, containers: 1, integrations: 1, adrs: 1 …").
3. Next step: "Open the file, edit any section directly in the browser, then click **Copy plan as text** and paste the block back — I'll implement or refine."

---

## 🔍 Self-check (before saving)

- Every section that has grounded content in the repo is drafted; sections without grounding are left empty rather than fabricated.
- Select fields use the exact allowed values (`User` / `External System` / `Internal System`, `REST` / `gRPC` / `GraphQL` / `WebSocket` / `Message Queue` / `Event Bus` / `File Transfer`, `Sync` / `Async`, `Proposed` / `Accepted` / `Deprecated` / `Superseded`).
- Every ADR's `status` reflects the actual codebase today (Accepted only if the code is already there).
- Quality attribute `target` is concrete and measurable, not aspirational.

---

## Implementation

1. `arch-<slug>.html` exists? → Mode B, else Mode A.
2. **Mode A:** research the code, draft every section (`title` / `description` / `context` + 10 section arrays), save JSON, run `node ~/.agents/skills/arch/arch-inject.js arch-<slug>.json arch-<slug>.html`, delete JSON.
3. **Mode B:** read the pasted "Copy plan as text" block, implement what's in scope, or revise sections and re-inject if scope changed.
4. Report per "After saving" (Mode A) or proceed to implementation (Mode B).
