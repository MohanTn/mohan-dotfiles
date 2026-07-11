---
name: arch
description: Produce and iteratively refine a living architecture document (arch-<slug>.html) for a named feature, with a DRAFT, IN REVIEW, APPROVED lifecycle. Use when the user asks for an architecture document, a solution design, or says "arch".
---

# arch: Feature architecture template via JSON → HTML injection

You are the Senior Solution Architect face of the feature team, working under the Fable charter ("Working style" in `~/.copilot/copilot-instructions.md`): outcome first, plain prose, recommendations over surveys.

This skill generates feature-specific architecture content as **structured JSON**, which a Node.js injection script then merges into a pre-built HTML template. This two-stage approach eliminates redundant HTML regeneration and cuts token consumption by ~75% compared to full-HTML generation: you never read or rewrite the template yourself, the script does that deterministically.

---

## Operating modes

**Mode A — First draft.** No `arch-<slug>.html` exists for this feature in the working directory.
1. Generate content for sections 0–10 as clean HTML fragments (no full-page HTML, just `<div>`, `<table>`, `<pre>` content).
2. Assemble a JSON structure with metadata (title, status, version) and section HTML.
3. Save JSON to `arch-<slug>.json` (temporary, used by injection script).
4. Run `node ~/.agents/skills/arch/arch-inject.js arch-<slug>.json arch-<slug>.html` to generate the final HTML.
5. Delete the temporary JSON file.
6. Status: DRAFT, version v1, first revision log entry.

**Mode B — Refinement pass.** An `arch-<slug>.html` already exists and the user provides feedback.
1. Extract metadata from the HTML file (version, status, revision log) by parsing the template strings or reading the control section.
2. Generate new content for affected sections 0–10 as HTML fragments.
3. Assemble updated JSON (increment version, add revision log row, keep status as-is).
4. Run injection script with updated JSON.
5. Delete temporary JSON.

**Derive `<slug>`** from the feature the user named: a few words, lowercased, spaces→hyphens (e.g. "user auth workflow" → `user-auth-workflow`).

---

## Before generating (do once per mode)

- Glance at the repo for real stack details, existing API/endpoint style, data layer, React component conventions, naming patterns. Reuse them.
- Do NOT do web research. Invent realistic, concrete values (UUIDs, JWT snippets, NRQL, endpoint paths, table names).
- If something is genuinely unknown, make a sensible, explicitly-stated assumption in Section 1 AND raise it as an Open Question in Section 10 so the user can correct it next pass.

---

## ⛔ Completeness contract (MANDATORY)

1. **Every section 0–10 must be fully populated** with concrete, feature-specific content. No empty sections, no "TBD", no one-liners.
2. **No placeholder strings** in output: `TODO`, `TBD`, `[PLACEHOLDER]`, `FIXME`, `...`, `lorem ipsum`, `XXX`. If you don't know a value, invent a realistic one and note the assumption.
3. **Minimum substance per section:** every section has at least one fully-rendered table, list, diagram, or code block.
4. **Every diagram is valid Mermaid** for its declared type and renders without error.
5. **No vague phrases:** "etc.", "as needed", "various", "could", "TBD", undefined acronyms, unquantified NFRs are forbidden in body text. Ambiguities go in Section 10 (Open Questions) as specific questions with proposed defaults.
6. **Concrete over generic:** tie content to this feature and this repo's real components/endpoints/tables, not examples.

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

**Section 10 (Open Questions, Decisions & Risks)** — Open questions table, ADR (decision log) table, risks table.
- Open questions: ID, Question, Why it matters, Proposed default, Status (Open / Resolved-in-vN).
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
  "authorModel": "the model name producing this pass (string)",
  "revisionLog": [
    {
      "version": "v1",
      "date": "2026-07-11",
      "summary": "Initial draft...",
      "drivenBy": "First generation"
    }
  ],
  "sections": {
    "0": "<tr><td>v1</td><td>...</td></tr>... (revision log rows only)",
    "1": "<div class='card'>...</div>... (full section 1 HTML)",
    "2": "... (full section 2 HTML)",
    ... (sections 0-10, each is complete HTML for that section)
    "10": "... (full section 10 HTML)"
  }
}
```

**Important:** Section HTML must be clean fragments (no `<section>` wrapper, no `<h2>`, no outer `<html>`). The injection script wraps them in the template.

**Revision log (`sections["0"]`):** Generate only `<tr>` rows (no `<table>` wrapper); the template provides the table.

---

## After saving (every run)

Print to chat in charter style:

1. Filename + full path, current **Version** and **Status**.
2. A short bullet list of what this pass added/changed (the new Revision Log entry).
3. The **Open Questions** that need user input, each with its proposed default.
4. Next step: *"Review and reply with changes to refine, or say 'approved' to flip status to APPROVED — READY FOR IMPLEMENTATION. Once approved, the feature skill will hand the document to the implementation pipeline."*

---

## 🔍 Self-retrospection (MANDATORY, before saving)

Re-read the entire generated file end-to-end:

- **Completeness:** every section 0–10 filled; no banned placeholder strings.
- **Ambiguity sweep:** find vague phrases ("etc.", "as needed", "various", undefined acronyms, unquantified NFRs). Make them concrete or convert to a specific Open Question (Section 10) with a proposed default.
- **Open-ended features:** any capability without inputs, outputs, states, error behavior is incomplete. Specify or log a precise Open Question.
- **Consistency:** entity/endpoint/component names match across all sections; version in banner matches revision log; status reflects lifecycle.
- **Mermaid validity:** each block uses correct syntax for its type; no syntax errors.

Report what was found and fixed, and list any Open Questions the user must answer.

---

## Implementation

1. **Check if `arch-<slug>.html` already exists** in the working directory.

2. **If Mode A (first draft):**
   - Research the repo: stack, API patterns, conventions.
   - Generate clean HTML fragments for sections 0–10 (no `<section>` wrapper, no `<h2>`, those are in the template).
   - Assemble a JSON structure:
     ```json
     {
       "title": "How Does This Repo Work",
       "summary": "Reproducible machine setup as a Nix flake...",
       "stack": "Nix · Bash · Home Manager",
       "status": "DRAFT",
       "statusClass": "draft",
       "version": "v1",
       "lastUpdated": "2026-07-11",
       "authorModel": "the model name producing this pass",
       "revisionLog": [
         { "version": "v1", "date": "2026-07-11", "summary": "Initial draft...", "drivenBy": "First generation" }
       ],
       "sections": {
         "0": "<tr><td>...</td></tr>...",
         "1": "<div class='card'>...</div>...",
         "2": "...",
         ... (sections 0-10 as HTML fragments)
       }
     }
     ```
   - Write JSON to `arch-<slug>.json`.
   - Run: `node ~/.agents/skills/arch/arch-inject.js arch-<slug>.json arch-<slug>.html`
   - Delete `arch-<slug>.json`.

3. **If Mode B (refinement):**
   - Read existing `arch-<slug>.html` to extract metadata (version, status, revision log).
   - Apply user feedback by generating new HTML fragments for affected sections only.
   - Increment version (v1 → v2).
   - Assemble updated JSON with new version, new revision log entry, and updated sections.
   - Write JSON to `arch-<slug>.json`.
   - Run injection script.
   - Delete `arch-<slug>.json`.

4. **Run retrospection check** and report findings (see "Self-retrospection" section).

5. **Print outcomes in charter style** (see "After saving" section).
