# arch: Feature architecture template via JSON → HTML injection

Generate feature architecture as structured JSON (injected into HTML template by a deterministic script, not regenerated each pass).

---

## Operating modes

**Mode A — First draft.** No `arch-<slug>.html` exists for this feature in the working directory.
1. Generate content for sections 0–10 as clean HTML fragments (no full-page HTML, just `<div>`, `<table>`, `<pre>` content), plus a single `aiOverview` summary and a structured `openQuestions` array (see below).
2. Assemble a JSON structure with metadata (title, status, version) and section HTML.
3. Save JSON to `arch-<slug>.json` (temporary, used by injection script).
4. Run `node ~/.agents/skills/arch/arch-inject.js arch-<slug>.json arch-<slug>.html` to generate the final HTML.
5. Delete the temporary JSON file.
6. Status: DRAFT, version v1, first revision log entry.

**Mode B — Refinement pass.** An `arch-<slug>.html` already exists and the user provides feedback.
1. Extract metadata from the HTML file (version, status, revision log) by parsing the template strings or reading the control section.
2. Generate new content for affected sections 0–10 as HTML fragments, updating `aiOverview` and `openQuestions` if the feature shape changed.
3. Assemble updated JSON (increment version, add revision log row, keep status as-is).
4. Run injection script with updated JSON.
5. Delete temporary JSON.

**Derive `<slug>`** from $ARGUMENTS lowercased, spaces→hyphens (e.g. "user auth workflow" → `user-auth-workflow`).

**Before generating:** research repo stack and conventions; invent concrete values (UUIDs, JWTs, paths, table names). Unknown values: assume in Section 1, question in Section 10.

---

## ⛔ Completeness contract (MANDATORY)

1. **Every section 0–10 must be fully populated** with concrete, feature-specific content. No empty sections, no "TBD", no one-liners.
2. **No placeholder strings** in output: `TODO`, `TBD`, `[PLACEHOLDER]`, `FIXME`, `...`, `lorem ipsum`, `XXX`. If you don't know a value, invent a realistic one and note the assumption.
3. **Minimum substance per section:** every section has at least one fully-rendered table, list, diagram, or code block.
4. **Every diagram is valid Mermaid** for its declared type and renders without error.
5. **No vague phrases:** "etc.", "as needed", "various", "could", "TBD", undefined acronyms, unquantified NFRs are forbidden in body text. Ambiguities go in Section 10 (Open Questions) as specific questions with proposed defaults.
6. **Concrete over generic:** tie content to this feature and this repo's real components/endpoints/tables, not examples.

---

## AI Overview (the `aiOverview` field, not a numbered section)

Write **one** condensed, human-readable paragraph (or short list) that is the single best summary of what will be implemented: the feature, the approach, the key components touched. This is the only place the full narrative gets restated — Sections 1–9 should stick to their own concern (data model, API, deployment, etc.) instead of re-explaining the feature from scratch each time. It renders in a highlighted card at the very top of the document, above Document Control, so the user reads it first.

---

## Section content requirements (generate these as clean HTML fragments)

Generate each section's content as a standalone HTML fragment (no `<section>` wrapper, no `<h2>`, those are in the template). The fragment is injected into `{{SECTION_N_CONTENT}}`.

Each section must contain:

**Section 0 (Document Control)** — *Template supplies status banner and approval gate; you supply revision log rows only.*
- Revision log: a series of `<tr>` rows (no `<table>` wrapper). Each row: Version, Date, Summary of change, Driven by.
- Inject into `{{REVISION_LOG_ROWS}}`.
- Example row: `<tr><td>v1</td><td>2026-07-11</td><td>Initial draft</td><td>First generation</td></tr>`

**Section 1 (Overview)** — Feature name, summary, audience/actors, dependencies, assumptions, out-of-scope, at-a-glance table.
- Use `.card` wrapper for grouping.
- Actors table: Name/Role, Responsibility, System(s) they interact with.
- Dependencies table: System, Purpose, Version/Location, Protocol.
- At-a-glance table: Owner, Repos touched, Data store, Auth method, Environments.

**Section 2 (Use Cases & Scope)** — Use-case flowchart, functional requirements table, non-functional requirements table.
- Mermaid flowchart (actor → use-case → system boundary).
- Functional requirements: ID (FR1), Requirement, Acceptance criteria.
- Non-functional requirements: Attribute (Performance, Security, etc.), Measurable target.

**Section 3 (C4)** — C4 Context and Container diagrams.
- Mermaid C4Context showing system in the wider landscape.
- Mermaid C4Container showing internal components.
- Label all relationships with protocol (HTTPS/REST, SQL, async/webhook).

**Section 4 (Domain & Data Model)** — Mermaid classDiagram, Mermaid erDiagram, migration impact note.
- Domain model: classes, relationships, key attributes.
- Entity-relationship diagram: tables, PK/FK, column types.
- State explicitly: "none" (and why) or the specific schema changes.

**Section 5 (API Design)** — Endpoint table, OpenAPI snippet in `<details>`, sequence diagram.
- Endpoints table: Method, Route, Auth, Request, Response, Status codes.
- OpenAPI 3.0 YAML inside `<details><summary>OpenAPI Spec</summary><pre>...</pre></details>`.
- Mermaid sequenceDiagram: React → API → domain → DB → external systems (include token exchange).

**Section 6 (UI/UX)** — User-flow flowchart, component hierarchy, lightweight ASCII wireframes.
- Mermaid flowchart: screen-by-screen user journey.
- Component hierarchy: Mermaid flowchart mapping React components to API endpoints.
- Wireframes: ASCII inside bordered boxes (`.card` divs with `<pre>` for ASCII art).

**Section 7 (Behaviour)** — State lifecycle diagram, activity/process diagram.
- Mermaid stateDiagram-v2: entity states and transitions.
- Mermaid flowchart: activity diagram for the main process, including error/retry branches.

**Section 8 (Deployment)** — Deployment architecture diagram, Terraform outline, GitLab pipeline diagram.
- Mermaid deployment flowchart: Docker containers, networks, cloud nodes, environments.
- Terraform: file list + key resources inside `<details><summary>Terraform Modules</summary><pre>...</pre></details>`.
- Mermaid pipeline flowchart: build → test → scan → docker → terraform → deploy, with gates.

**Section 9 (Monitoring)** — Golden signals table, custom alerts table, incident flow diagram, dashboard widget list.
- Golden signals table: Metric, Source, Target/SLO.
- Alerts table: Alert name, NRQL query, Threshold, Severity, Notification channel.
- Mermaid sequenceDiagram: New Relic alert → webhook → ServiceNow → on-call → resolution.
- Dashboard widgets: a bulleted list.

**Section 10 (Open Questions, Decisions & Risks)** — ADR (decision log) table and risks table only. Open Questions are **not** part of this HTML fragment: the template renders them from the structured `openQuestions` JSON field as an interactive table with a per-question answer box and a "Copy Q&A for Claude Code" button, so the user can fill in answers and paste them straight back into a refinement pass.
- Decisions: Decision, Options considered, Choice + rationale, Date.
- Risks: Risk, Likelihood, Impact, Mitigation.

---

## JSON Output Format (For Generation)

**You generate this structure and write it to `arch-<slug>.json`:**

```json
{
  "title": "Feature name (string)",
  "summary": "One-sentence summary (string)",
  "stack": "Stack badges separated by · (string)",
  "status": "DRAFT|IN REVIEW|APPROVED — READY FOR IMPLEMENTATION (string)",
  "statusClass": "draft|review|approved (string, lowercase)",
  "version": "v1, v2, etc. (string)",
  "lastUpdated": "2026-07-11 (date string)",
  "authorModel": "Claude Haiku 4.5 (string)",
  "aiOverview": "<p>...</p> (HTML fragment, the single condensed implementation summary — write once, don't repeat this narrative in every section)",
  "revisionLog": [
    {
      "version": "v1",
      "date": "2026-07-11",
      "summary": "Initial draft...",
      "drivenBy": "First generation"
    }
  ],
  "openQuestions": [
    {
      "id": "OQ1",
      "question": "Specific, answerable question (string)",
      "whyItMatters": "Why this needs an answer (string)",
      "proposedDefault": "What we'll assume if unanswered (string)",
      "status": "Open|Resolved-in-vN (string)"
    }
  ],
  "sections": {
    "0": "<tr><td>v1</td><td>...</td></tr>... (revision log rows only)",
    "1": "<div class='card'>...</div>... (full section 1 HTML)",
    "2": "... (full section 2 HTML)",
    ... (sections 0-10, each is complete HTML for that section)
    "10": "... (Decisions/ADR + Risks tables only; Open Questions come from the openQuestions field above)"
  }
}
```

**Important:** Section HTML must be clean fragments (no `<section>` wrapper, no `<h2>`, no outer `<html>`). The injection script wraps them in the template.

**Revision log (`sections["0"]`):** Generate only `<tr>` rows (no `<table>` wrapper); the template provides the table.

---

## After saving

Print: Filename, Version, Status, revision log summary, Open Questions, and next step: "Reply with changes or say 'approved' to gate APPROVED — READY FOR IMPLEMENTATION."

---

## 🔍 Self-retrospection (MANDATORY)

Before saving, verify:
- Completeness: every section 0–10 filled; no TBD/placeholder strings.
- `aiOverview` is written once and Sections 1–9 don't restate it as a narrative.
- No vague phrases; ambiguities are precise entries in `openQuestions`, not a table inside `sections["10"]`.
- Names consistent across sections; version matches revision log.
- Mermaid syntax valid for each diagram type.

Report findings and the Open Questions the user must resolve.

---

## Implementation

1. Check `arch-<slug>.html` exists → Mode A (new) or Mode B (refine).
2. **Mode A:** research repo, generate section HTML plus `aiOverview` and `openQuestions`, assemble JSON per schema, run `node ~/.agents/skills/arch/arch-inject.js arch-<slug>.json arch-<slug>.html`, delete JSON.
3. **Mode B:** extract metadata from HTML, regenerate affected sections (and `aiOverview`/`openQuestions` if the feature shape changed), increment version, assemble JSON, run injection script, delete JSON.
4. Run self-retrospection per above, report findings and Open Questions.

