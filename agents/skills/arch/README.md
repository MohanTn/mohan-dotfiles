# Architecture command: shared template + injection script

This folder is the common layer shared by Claude Code's `/arch` command (`claude/commands/arch.md`) and Copilot CLI's `arch` skill (`copilot/skills/arch/SKILL.md`): one HTML template and one Node.js injection script, with no tool-specific content, deployed once to `~/.agents/skills/arch/` (see `nix/agents.nix`) and referenced by both tools at that fixed path. Neither `claude/` nor `copilot/` keeps its own copy.

The system is optimized for token efficiency using a two-stage process: content generation (the AI) and template injection (the Node.js script).

## Workflow

### Stage 1: Content Generation (the AI)
The AI generates feature-specific architecture content as **structured JSON** (sections 0–10 plus metadata). This is token-efficient because:
- No HTML boilerplate regeneration
- Only actual content is generated
- JSON is smaller than full HTML

### Stage 2: Template Injection (Script)
`arch-inject.js` reads the JSON and merges it into `arch-template.html`. This is fast and deterministic; the AI never reads or rewrites the template itself.

## Usage

### As a User
```bash
# First draft
/arch how does this repo work

# Refinement (if arch-how-does-this-repo-work.html already exists)
/arch how does this repo work
# Provide feedback; the AI updates the JSON and re-injects
```

### Manual Injection (if needed)
```bash
# From the deployed location (either tool, same path):
node ~/.agents/skills/arch/arch-inject.js arch-feature.json arch-feature.html

# The third (template path) argument is optional; it defaults to
# arch-template.html next to the script, so this also works from a checkout:
node agents/skills/arch/arch-inject.js arch-feature.json arch-feature.html
```

## JSON Structure Example

The AI generates a file like `arch-feature.json`:

```json
{
  "title": "User Authentication Workflow",
  "summary": "OAuth 2.0 integration for single sign-on across all services",
  "stack": "Node.js · React · PostgreSQL · Auth0",
  "status": "DRAFT",
  "statusClass": "draft",
  "version": "v1",
  "lastUpdated": "2026-07-11",
  "authorModel": "Claude Haiku 4.5",
  "aiOverview": "<p>Single condensed summary of what will be implemented — the only place the narrative is stated in full.</p>",
  "revisionLog": [
    {
      "version": "v1",
      "date": "2026-07-11",
      "summary": "Initial architecture draft covering OAuth flow, API design, and deployment model",
      "drivenBy": "First generation"
    }
  ],
  "openQuestions": [
    {
      "id": "OQ1",
      "question": "Should tokens be revocable server-side?",
      "whyItMatters": "Affects logout and session-kill UX",
      "proposedDefault": "Yes, via a revocation list",
      "status": "Open"
    }
  ],
  "sections": {
    "0": "<tr><td>v1</td><td>2026-07-11</td><td>Initial draft...</td><td>First generation</td></tr>",
    "1": "<div class='card'><h3>Feature Summary</h3><p>...</p></div>...",
    "2": "...",
    ... (sections 0-10)
    "10": "... (Decisions/ADR + Risks tables only; Open Questions render from openQuestions above)"
  }
}
```

The script then runs:
```bash
node arch-inject.js arch-feature.json arch-feature.html
```

Output: `arch-feature.html` (fully rendered, ready to share)

## Files

- **arch-template.html** — Pre-built HTML template with `{{PLACEHOLDER}}` markers for content injection: sticky left-hand table of contents with scrollspy highlighting, a status banner colored by lifecycle stage, a highlighted AI Overview card at the top, card/table styling, an interactive Open Questions table (per-question answer textarea plus a "Copy Q&A for Claude Code" button that copies each question and its typed answer to the clipboard), and Mermaid diagram rendering.
- **arch-inject.js** — Node.js script that reads JSON and injects content into the template. Handles HTML escaping and placeholder replacement (including the `aiOverview` card and the `openQuestions` interactive rows); the template path is optional and defaults to `arch-template.html` next to the script.
- **arch-inject.test.js** — Unit tests for the injection script and template contract. Run with `node --test agents/skills/arch/arch-inject.test.js`. Covers HTML escaping, revision log and open-questions rendering, placeholder completeness, and that section/overview HTML is injected raw (not escaped) while metadata is escaped.

The instruction files that drive generation, `claude/commands/arch.md` (Claude Code) and `copilot/skills/arch/SKILL.md` (Copilot CLI), stay in their own tool's directory: they're prose, not shared boilerplate, and differ slightly in voice and path references (`~/.claude/CLAUDE.md` vs `~/.copilot/copilot-instructions.md`, "$ARGUMENTS" vs "the feature the user named"). Both point at this folder's script and template by the same fixed `~/.agents/skills/arch/` path.

## Token Savings

| Approach | Tokens | Notes |
|----------|--------|-------|
| Old (full HTML generation) | ~20,000 | AI generates entire HTML + template |
| New (JSON + script injection) | ~5,000–7,000 | AI generates only content; script handles template |
| **Savings** | **~65–75%** | Huge reduction, especially for refinement passes |

## Refinement Workflow

1. User provides feedback: "Add ADR section, clarify Section 5 on API endpoints"
2. The AI reads existing HTML to extract current version/status
3. The AI generates new JSON with updated sections only
4. Script injects new JSON (same filename, version increments v1 → v2)
5. User reviews updated HTML

Subsequent refinements reuse the template, so token cost stays low (~5K per pass).

## Extending

To add new metadata fields or sections:
1. Update `arch-template.html` with new `{{PLACEHOLDER}}` markers
2. Update `arch-inject.js` to handle the new replacements
3. Update `claude/commands/arch.md` and `copilot/skills/arch/SKILL.md` to document the new JSON keys (both, they aren't shared)
4. The AI's next generation will use the new format automatically

---

For detailed instructions on section content, see `claude/commands/arch.md` or `copilot/skills/arch/SKILL.md`.
