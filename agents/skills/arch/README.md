# arch: shared template + injection script

The common layer behind Claude Code's `/arch` command (`claude/commands/arch.md`) and Copilot CLI's `arch` skill (`copilot/skills/arch/SKILL.md`): one HTML template and one Node.js injection script, no tool-specific content, deployed once to `~/.agents/skills/arch/` (see `nix/agents.nix`) and referenced by both tools at that fixed path. Neither `claude/` nor `copilot/` keeps its own copy.

## What the document is for

`/arch` produces a **feature plan decision tool**, not a spec you read passively. The AI breaks the feature into topics/areas, gives each a set of options with pros and cons, and seeds a technical-details table — then the human picks an option per topic, edits the table, and exports the result. It's a working page, not a review artifact: everything (topics, options, tech rows, counts) is editable and persists per browser via `localStorage`.

- **Topics / Areas** — one card per decision the feature requires. Each has open questions (free text) and a list of options, each with pros/cons. The human clicks **Select** on the option they want; only one selection per topic.
- **Decision Summary** — auto-derived list of topic → selected option, flagging any topic still undecided.
- **Technical Details** — a table of implementation actions (create/update file + comment) plus counts of files to create/update and unit/integration tests, all editable.
- **Approval & Export** — **Copy plan for AI** serializes the whole page (prompt, topics with selections, tech rows, counts) as plain text for the human to paste back; **Reset** clears the page.

## Two-stage workflow

1. **Content (the AI).** Generates the plan as **structured JSON** — `title`, `prompt`, `topics` (with pre-populated options/pros/cons), `techRows`, `counts`. Cheap in tokens: no template boilerplate is regenerated.
2. **Injection (the script).** `arch-inject.js` merges that JSON into `arch-template.html` deterministically, embedding it as the page's initial state. The AI never reads or rewrites the template.

## Usage

```bash
# First draft
/arch billing retry logic

# Refinement: open the file, select an option per topic, edit the tech-details
# table, then click "Copy plan for AI" and paste the block back so the AI can
# proceed with implementation.
```

Manual injection (either tool, same path):

```bash
node ~/.agents/skills/arch/arch-inject.js arch-feature.json arch-feature.html
# The third (template-path) argument is optional; it defaults to
# arch-template.html next to the script, so this also works from a checkout:
node agents/skills/arch/arch-inject.js arch-feature.json arch-feature.html
```

## JSON structure

```json
{
  "title": "Billing retry logic",
  "prompt": "Retry failed card charges with backoff before dunning.",
  "topics": [
    {
      "id": "topic-1",
      "name": "Retry strategy",
      "questions": ["How many attempts before dunning?"],
      "options": [
        { "id": "opt-1", "name": "Fixed backoff", "pros": "simple to reason about", "cons": "slow to adapt to failures" },
        { "id": "opt-2", "name": "Exponential backoff", "pros": "adapts fast, industry standard", "cons": "more moving parts" }
      ],
      "selectedOptionId": null
    }
  ],
  "techRows": [
    { "id": "row-1", "action": "create", "file": "src/billing/retry.js", "comment": "new retry scheduler" }
  ],
  "counts": { "create": 1, "update": 2, "unit": 3, "integration": 1 }
}
```

Leave `selectedOptionId` `null` — the human picks it in the browser. `id` fields must be unique strings; any scheme works (`topic-1`, `T1`, a slug) as long as topic option ids and tech row ids don't collide with each other.

## Files

- **arch-template.html** — the template with `{{FEATURE_TITLE}}` and `{{INITIAL_DATA_JSON}}` markers. Renders topics/options/tech-table entirely client-side from the injected data object; no server-side row building.
- **arch-inject.js** — reads JSON, escapes the title, and embeds the rest of the plan as a JSON literal (`INITIAL_DATA`) inside a `<script>` tag, escaping `</script>` breakout and the U+2028/U+2029 line-terminator characters that `JSON.stringify` leaves raw. Fills in defaults (`normalizePlan`) so a sparse JSON input still renders a valid page. Template path is optional.
- **arch-inject.test.js** — unit tests for the injection script and template contract. Run with `node --test agents/skills/arch/arch-inject.test.js`. Covers escaping, script-breakout/line-terminator safety, default-filling, and placeholder completeness.

The instruction files that drive generation stay in each tool's directory (`claude/commands/arch.md`, `copilot/skills/arch/SKILL.md`): they're prose, not shared boilerplate, and differ in voice and path references. Both point at this folder's script and template by the same fixed `~/.agents/skills/arch/` path.

## Extending

To add a field: add the `{{PLACEHOLDER}}` (or extend `normalizePlan`) in `arch-inject.js` / `arch-template.html` with a test, then document the new JSON key in **both** `claude/commands/arch.md` and `copilot/skills/arch/SKILL.md` (they aren't shared). The AI's next generation picks up the new format.
