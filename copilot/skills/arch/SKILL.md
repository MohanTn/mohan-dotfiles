---
name: arch
description: Take a feature the user has in mind and turn it into a feature plan decision tool (arch-<slug>.html) — topics broken out of the concept, each with real options and pros/cons grounded in the code, plus an editable technical-details table. The user picks an option per topic and exports the plan back. Use when the user asks for a feature plan, wants to weigh implementation options, or says "arch".
---

# arch: Feature plan decision tool via JSON → HTML injection

Take a feature the user has in mind and turn it into a **feature plan decision tool**: topics/areas broken out of the concept, each with a few real options carrying pros and cons, plus a technical-details table the user can edit. You generate structured JSON; a deterministic script (`arch-inject.js`) injects it into the HTML template — you never rewrite the template. The user's job is to click **Select** on the option they want per topic, edit the tech-details table, then export the plan back to you.

**Prime directive:** give the user real decisions with real trade-offs, grounded in the actual code — not vague filler options that all sound the same. If a topic only has one sane option, don't force a second; drop the topic to a single-option list or fold it into the prompt/summary instead.

---

## Operating modes

**Mode A — First draft.** No `arch-<slug>.html` exists in the working directory.
1. Research the repo (see below). Break the feature into topics, each with 2-4 concrete options with pros/cons pulled from how this codebase actually works. Draft an initial technical-details table and counts.
2. Assemble JSON, save to `arch-<slug>.json` (temporary).
3. Run `node ~/.agents/skills/arch/arch-inject.js arch-<slug>.json arch-<slug>.html`.
4. Delete the temporary JSON.

**Mode B — Refinement pass.** `arch-<slug>.html` exists and the user pastes the doc's **"Copy plan for AI"** block (prompt, each topic's selected option, the tech-details table, and the counts).
1. Read the selections. Any topic marked `(no selection)` needs a decision from the user before you proceed — ask, don't guess.
2. With every topic decided, implement the feature accordingly, or update the plan (new topics, revised tech-details rows) and re-inject if the scope shifted.

**Derive `<slug>`** from the feature the user named: a few words, lowercased, spaces→hyphens (e.g. "billing retry logic" → `billing-retry-logic`).

---

## Before generating (research, don't guess)

- Read the actual code the feature touches before proposing options — pros/cons should reference real constraints (existing patterns, files, libraries in use), not generic tradeoffs.
- Never do web research; ground options in this repo.

---

## Topics (`topics` array)

One entry per decision the feature requires. Each: `id`, `name` (short), `questions` *(opt: array of open questions worth surfacing, not necessarily answered yet)*, `options` (array of `{ id, name, pros, cons }`), `selectedOptionId: null` (always null — the user picks it in the browser).

Keep options concrete and comparable: same dimension, different tradeoff. "Do it" vs "don't do it" is rarely a useful pair — prefer real alternative approaches.

---

## Technical Details (`techRows` + `counts`)

`techRows`: your best-guess implementation actions, each `{ id, action, file, comment }` (`action` typically `create` or `update`). These are a starting draft the user edits, not a locked plan — populate what you can tell from the repo today, and leave the rest for the user to fill in once topics are decided.

`counts`: `{ create, update, unit, integration }` — rough estimate matching the tech rows.

---

## JSON Output Format

Write this to `arch-<slug>.json`:

```json
{
  "title": "Feature name",
  "prompt": "The feature request, restated concretely",
  "topics": [
    {
      "id": "topic-1",
      "name": "Short topic name",
      "questions": ["An open question worth surfacing"],
      "options": [
        { "id": "opt-1", "name": "Option A", "pros": "...", "cons": "..." },
        { "id": "opt-2", "name": "Option B", "pros": "...", "cons": "..." }
      ],
      "selectedOptionId": null
    }
  ],
  "techRows": [
    { "id": "row-1", "action": "create", "file": "path/to/file.js", "comment": "what it does" }
  ],
  "counts": { "create": 1, "update": 1, "unit": 1, "integration": 0 }
}
```

`id` fields just need to be unique strings; any scheme works.

---

## After saving

Print to chat:
1. Filename.
2. The topics you broke the feature into, in one line each.
3. Next step: "Open the file, pick an option for each topic, adjust the technical-details table if needed, then click **Copy plan for AI** and paste it back — I'll implement it."

---

## 🔍 Self-check (before saving)

- Every topic has real, comparable options grounded in this repo, not filler.
- No topic is a false binary dressed up as a decision.
- Tech-details rows reference real paths/patterns from the repo, not invented ones.

---

## Implementation

1. `arch-<slug>.html` exists? → Mode B, else Mode A.
2. **Mode A:** research the code, break the feature into topics with options, draft tech-details rows + counts, assemble JSON, run `node ~/.agents/skills/arch/arch-inject.js arch-<slug>.json arch-<slug>.html`, delete JSON.
3. **Mode B:** read the pasted plan, confirm every topic is decided (ask if not), then implement — or revise the plan and re-inject if scope changed.
4. Report per "After saving" (Mode A) or proceed to implementation (Mode B).
