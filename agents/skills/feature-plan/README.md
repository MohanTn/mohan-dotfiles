# featurePlan: shared template + injection script + WebSocket AI integration

The common layer behind Claude Code's `/featurePlan` command (`claude/commands/featurePlan.md`) and Copilot CLI's `featurePlan` skill (`copilot/skills/featurePlan/SKILL.md`): one HTML template, one Node.js injection script, WebSocket client for real-time AI chat, and a harness listener for bidirectional communication. Both tools reference this directory at its fixed path (`agents/skills/featurePlan/` deployed to `~/.agents/skills/featurePlan/` via `nix/agents.nix`). Neither `claude/` nor `copilot/` keeps its own copy of the template or the inject script.

The new interactive mode allows users to ask clarifying questions about design decisions while editing the plan, with an AI agent responding in real-time and suggesting fine-grained patches to plan sections.

## What the document is for

`/featurePlan` produces a **co-authored feature implementation plan**: the AI drafts, the human decides. The AI seeds an editable HTML page (feature overview, open questions, design patterns, solution approach, ordered file manifest, pseudo-code, contracts, edge cases, tests — redundant sections skipped, see below). The human resolves the **Open Questions**, edits any section in the browser, and exports via **Copy AI-Ready Plan**. The export diffs against the AI's original draft and tags human changes `[HUMAN-EDITED]` / `[HUMAN-ADDED]` so the implementing AI treats them as authoritative; an undecided open question exports as `UNRESOLVED` and blocks implementation. Everything persists per document via `localStorage` (key derived from `document.title`, so different `featurePlan-<slug>.html` files don't share state).

The on-page sections in order:

- **Feature Overview** — title, target module, captured intent (user's ask verbatim + inferred reading), user story/goal, and existing-codebase context.
- **Open Questions & Decisions** — ambiguities the AI couldn't resolve, each with drafted options and a human-owned `decision` field. Empty decision = `UNRESOLVED` in the export; the approval gate shows the unresolved count live.
- **Acceptance Criteria** — testable "done" conditions, each with how to verify it.
- **Design Patterns & Architectural Overrides** — core pattern (e.g. Layered), business-logic pattern (e.g. Transaction Script), specific implementations (Factory vs Builder, Repository vs DAO), and explicit overrides/constraints.
- **Solution Approach & Rationale** — settled design decisions and trade-offs; anything still open lives in Open Questions instead.
- **Resulting Folder Structure** — ASCII tree derived by the inject script from the file manifest (`[CREATE]` / `[UPDATE]` / `[DELETE]` markers); the AI no longer authors it, the human can still edit it.
- **File Change Manifest (In Order of Execution)** — ordered list of files with `action` (create/update/delete), `path`, `description`, and `pseudoCode` per file. Sorted by a numeric `order` field; reorderable in the UI. The single source of truth for touched paths.
- **Core Business Logic (Detailed Pseudo-Code)** — *skippable:* only cross-file orchestration the manifest pseudo-code doesn't already show.
- **Function / API Contracts** — *skippable:* only new/changed public entry points.
- **Edge Cases & Error Handling** — what happens when things go wrong.
- **Testing Strategy** — *skippable:* only scenarios beyond the acceptance-criteria verifications.

Skippable sections keep each fact in exactly one place; the AI emits `[]` when another section already carries the content.

The **Export & Execution** card adds a **Copy AI-Ready Plan** button (full document as plain text, ready to paste into any coding AI) and a **Reset all data** button.

## Two-stage workflow

1. **Content (the AI).** Generates the plan as **structured JSON** — scalar fields (`title`, `module`, `intent`, `goal`, `context`, `patternCore`, `patternBusiness`, `patternSpecific`, `patternOverrides`) and section arrays (`openQuestions`, `solutionApproach`, `acceptanceCriteria`, `files`, `logicSteps`, `contracts`, `edgeCases`, `testScenarios`). Cheap in tokens: no template boilerplate is regenerated, and `folderStructure` is derived from `files[]` (supply it only to override).
2. **Injection (the script).** `featurePlan-inject.js` merges that JSON into `featurePlan-template.html` deterministically, embedding it as the page's `INITIAL_DATA`. The AI never reads or rewrites the template. `INITIAL_DATA` doubles as the provenance baseline the export diffs against.

## Usage

### Standard (offline) mode
```bash
# First draft
/featurePlan add two-factor authentication

# Refinement: open the file, edit any section directly in the browser, click
# "Copy AI-Ready Plan", paste the block back so the AI can implement.
```

### Interactive mode (requires harness)
The harness (Claude Code, Copilot, Pi) can launch an interactive session:

```javascript
// In the harness (e.g. Claude Code skill):
const listener = require('./featurePlan-harness-listener');
const port = 3001; // or any free port

const server = listener.createServer(port, {
  aiAgent: async (input) => {
    const { section, question, plan } = input;
    // Forward to your AI agent, receive response + patches
    return {
      response: 'Your clarification here',
      patches: [
        { type: 'patch', section: 'files', itemId: 'f-1', field: 'description', value: 'Updated', action: 'update' }
      ]
    };
  }
});

await server.start();
// Open the HTML with query param: file:///path/to/featurePlan.html?socket-port=3001
// User can now type questions and see real-time responses + plan updates
await server.stop(); // when done
```

User workflow in interactive mode:
1. Hover over any section header and click the **💬 Comment** button.
2. Side panel opens on the right; type a question (e.g., "Why singleton pattern?").
3. Click **Send**. The question is transmitted over WebSocket to the harness.
4. AI responds with clarification text and optional patch operations.
5. Plan sections update live in the browser.
6. Comments are stored locally in browser storage, not exported.
7. Continue editing and building the plan.

Manual injection (either tool, same path):

```bash
node ~/.agents/skills/featurePlan/featurePlan-inject.js featurePlan.json featurePlan.html
# The third (template-path) argument is optional; it defaults to
# featurePlan-template.html next to the script, so this also works from a checkout:
node agents/skills/featurePlan/featurePlan-inject.js featurePlan.json featurePlan.html
```

## JSON structure

Top-level keys: 9 scalar pattern/feature fields (`title`, `module`, `intent`, `goal`, `context`, `patternCore`, `patternBusiness`, `patternSpecific`, `patternOverrides`) plus 8 section arrays. `folderStructure` is accepted but normally omitted (derived from `files[]`).

```json
{
  "title": "Add two-factor authentication",
  "module": "User Service",
  "intent": "User asked: \"add 2FA to login\". Inferred: TOTP second factor verified at login; enrollment managed from the profile page.",
  "goal": "As a user, I want to require a second factor at login so that a stolen password alone cannot compromise my account.",
  "context": "Existing User.php, AuthService.php, and a users table with columns id, email, password_hash.",
  "patternCore": "Layered (Controller -> Service -> Repository)",
  "patternBusiness": "Transaction Script",
  "patternSpecific": "Use Repository for User; Factory for OTP enrollment DTO.",
  "patternOverrides": "No separate Repository for OTP — reuse UserRepository.",
  "openQuestions": [
    { "id": "q1", "question": "Is TOTP enrollment mandatory at next login, or opt-in from the profile page?", "options": "A) Mandatory at next login (recommended)\nB) Opt-in from profile settings", "decision": "" }
  ],
  "solutionApproach": [
    { "id": "s1", "aspect": "Architecture", "rationale": "Separate TOTP logic into its own service to keep auth concerns modular. This allows future 2FA methods (SMS, hardware keys) without touching AuthService." },
    { "id": "s2", "aspect": "Performance", "rationale": "Store TOTP secrets encrypted in the users table, not in a separate table. Reduces DB lookups during login; trade-off is we can't easily audit secret rotations, but we can log them in an audit table separately." }
  ],
  "acceptanceCriteria": [
    { "id": "a1", "criterion": "Given a user with 2FA enabled, when they log in without a code, then the login is rejected with reason 2fa_required.", "verification": "Integration test on POST /login." }
  ],
  "files": [
    { "id": "f1", "order": 1, "action": "create", "path": "src/Security/TotpService.php", "description": "TOTP enrollment + verification", "pseudoCode": "class TotpService {\n  public function enroll(User $user): string { /* generate secret */ }\n  public function verify(User $user, string $code): bool { /* check code */ }\n}" },
    { "id": "f2", "order": 2, "action": "update", "path": "src/Auth/AuthService.php", "description": "Wire TOTP into login flow", "pseudoCode": "public function login($email, $password, $code) { /* verify + then 2fa */ }" }
  ],
  "logicSteps": [
    { "id": "l1", "step": "Validate credentials", "pseudo": "1. Check email format\n2. Look up user\n3. Verify password_hash" }
  ],
  "contracts": [
    { "id": "c1", "name": "POST /api/v2/verify-2fa", "inputs": "{ userId: string, code: string }", "outputs": "{ ok: boolean, reason?: string }" }
  ],
  "edgeCases": [
    { "id": "e1", "condition": "User has 2FA enabled but no code provided", "handling": "Return 401 with reason \"2fa_required\"." }
  ],
  "testScenarios": [
    { "id": "t1", "target": "TotpService::enroll()", "scenario": "Returns a base32 secret that decodes to 20+ digits." },
    { "id": "t2", "target": "AuthService::login() with bad code", "scenario": "Returns 401 and increments failed_2fa counter." }
  ]
}
```

Allowed select values: `files.action` ∈ { create, update, delete }. The script fills defaults for missing fields, so a sparse input still renders a valid page; `patternCore` / `patternBusiness` default to the conventional layered + transaction-script scaffolding if absent.

`id` fields just need to be unique strings; any scheme works. The inject script preserves `id` so the user's existing in-browser edits stay linked to the right item across re-injections, and coerces `files[].order` to a Number so the sort works on injected items too.

## Files

- **featurePlan-template.html** — the template with `{{FEATURE_TITLE}}` (for `<title>` and `<h1>`) and `{{INITIAL_DATA_JSON}}` markers. Renders every section entirely client-side from the injected data object. Uses `localStorage` key `'feature-impl-plan:' + document.title` so each `featurePlan-<slug>.html` keeps its own state. Migrates the legacy `'feature-impl-plan-data'` (used by the original pasted template's single-key layout) to the per-doc key on first load, then deletes the legacy entry. Keeps a `SEED` snapshot of `INITIAL_DATA` at load; the export compares against it to emit `[HUMAN-EDITED]` / `[HUMAN-ADDED]` provenance tags. **NEW:** Includes a side panel for inline comments/questions and real-time AI chat when launched via harness with `?socket-port=PORT`.
- **featurePlan-inject.js** — reads JSON, escapes the title, and embeds the rest of the plan as a JSON literal (`INITIAL_DATA`) inside a `<script>` tag, escaping `</script>` breakout and the U+2028/U+2029 line-terminator characters that `JSON.stringify` leaves raw. `normalizePlan` applies per-section defaults via a single `ITEM_FIELD_DEFAULTS` table and derives `folderStructure` from `files[]` when absent (`deriveFolderStructure`). Template path is optional. **NEW:** Exports `createPatch` and `createAddPatch` utilities for harness to build patch operations.
- **featurePlan-socket-client.js** — WebSocket client for browser page. Manages connection to harness listener, sends user questions over socket, receives AI responses and patch operations, auto-reconnects on disconnect, queues messages when offline. Exports `FeaturePlanSocket` class for use in the template.
- **featurePlan-harness-listener.js** — WebSocket server for harness (Claude Code, Copilot, Pi). Listens for questions from the HTML page, forwards to an AI agent function, sends patch operations back to the page. Supports custom AI agent or defaults to a no-op echo. Broadcasts responses to all connected clients.
- **featurePlan-inject.test.js** — unit tests for the injection script and template contract. Run with `node --test featurePlan-inject.test.js`. Covers escaping, script-breakout/line-terminator safety, default-filling for both top-level and per-section fields, and an end-to-end disk round-trip.
- **featurePlan-harness-listener.test.js** — unit tests for the WebSocket listener. Covers instantiation, server start/stop, AI agent integration.
- **package.json** — dependencies (ws for WebSocket). Run `npm install` before using the harness listener.

The instruction file that drives generation is this folder's `SKILL.md`; it points at the script and template by the fixed `~/.agents/skills/featurePlan/` path.

## Extending

To add a new section: add its HTML container + add button + `bindAdd` call to the template with a `renderXxx()` function and its field list in the export's `SECTION_FIELDS` (for provenance tagging), then add the section key + per-field defaults to `ITEM_FIELD_DEFAULTS` in this folder's inject script, plus a test. The template and the script each hold one half of the per-section schema; both must evolve together, and both files contain a `NOTE` comment pointing at the other to keep them in sync. Finally, document the new JSON key in `SKILL.md`. The AI's next generation picks up the new format.
