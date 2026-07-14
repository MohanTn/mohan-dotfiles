# featurePlan: shared template + injection script

The common layer behind Claude Code's `/featurePlan` command (`claude/commands/featurePlan.md`) and Copilot CLI's `featurePlan` skill (`copilot/skills/featurePlan/SKILL.md`): one HTML template and one Node.js injection script, no tool-specific content. Both tools reference this directory at its fixed path (`agents/skills/featurePlan/` deployed to `~/.agents/skills/featurePlan/` via `nix/agents.nix`). Neither `claude/` nor `copilot/` keeps its own copy of the template or the inject script.

## What the document is for

`/featurePlan` produces a **feature implementation plan** as a working document, not a passive spec. The AI drafts the plan's structure (feature overview, design patterns, ordered file manifest, core business logic pseudo-code, function/API contracts, edge cases, testing strategy) and seeds an editable HTML page. The human then edits every section in the browser — reordering files, refining pseudo-code, adding edge cases — and exports the result as plain text via **Copy AI-Ready Plan**. Everything is editable in-browser and persists per document via `localStorage` (key derived from `document.title`, so different `featurePlan-<slug>.html` files don't share state).

The on-page sections in order:

- **Feature Overview** — title, target module, user story/goal, and existing-codebase context.
- **Design Patterns & Architectural Overrides** — core pattern (e.g. Layered), business-logic pattern (e.g. Transaction Script), specific implementations (Factory vs Builder, Repository vs DAO), and explicit overrides/constraints.
- **File Change Manifest (In Order of Execution)** — ordered list of files with `action` (create/update/delete), `path`, `description`, and `pseudoCode` per file. Sorted by a numeric `order` field; reorderable in the UI.
- **Core Business Logic (Detailed Pseudo-Code)** — step-by-step algorithm that an AI can translate into actual code.
- **Function / API Contracts** — entry points (Controllers, Event Handlers, CLI commands) with inputs and outputs.
- **Edge Cases & Error Handling** — what happens when things go wrong.
- **Testing Strategy** — per-file/per-method test scenarios.

The **Export & Execution** card adds a **Copy AI-Ready Plan** button (full document as plain text, ready to paste into any coding AI) and a **Reset all data** button.

## Two-stage workflow

1. **Content (the AI).** Generates the plan as **structured JSON** — scalar fields (`title`, `module`, `goal`, `context`, `patternCore`, `patternBusiness`, `patternSpecific`, `patternOverrides`) and section arrays (`files`, `logicSteps`, `contracts`, `edgeCases`, `testScenarios`). Cheap in tokens: no template boilerplate is regenerated.
2. **Injection (the script).** `featurePlan-inject.js` merges that JSON into `featurePlan-template.html` deterministically, embedding it as the page's `INITIAL_DATA`. The AI never reads or rewrites the template.

## Usage

```bash
# First draft
/featurePlan add two-factor authentication

# Refinement: open the file, edit any section directly in the browser, click
# "Copy AI-Ready Plan", paste the block back so the AI can implement.
```

Manual injection (either tool, same path):

```bash
node ~/.agents/skills/featurePlan/featurePlan-inject.js featurePlan.json featurePlan.html
# The third (template-path) argument is optional; it defaults to
# featurePlan-template.html next to the script, so this also works from a checkout:
node agents/skills/featurePlan/featurePlan-inject.js featurePlan.json featurePlan.html
```

## JSON structure

Top-level keys: 8 scalar pattern/feature fields (`title`, `module`, `goal`, `context`, `patternCore`, `patternBusiness`, `patternSpecific`, `patternOverrides`) plus 5 section arrays.

```json
{
  "title": "Add two-factor authentication",
  "module": "User Service",
  "goal": "As a user, I want to require a second factor at login so that a stolen password alone cannot compromise my account.",
  "context": "Existing User.php, AuthService.php, and a users table with columns id, email, password_hash.",
  "patternCore": "Layered (Controller -> Service -> Repository)",
  "patternBusiness": "Transaction Script",
  "patternSpecific": "Use Repository for User; Factory for OTP enrollment DTO.",
  "patternOverrides": "No separate Repository for OTP — reuse UserRepository.",
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

- **featurePlan-template.html** — the template with `{{FEATURE_TITLE}}` (for `<title>` and `<h1>`) and `{{INITIAL_DATA_JSON}}` markers. Renders every section entirely client-side from the injected data object. Uses `localStorage` key `'feature-impl-plan:' + document.title` so each `featurePlan-<slug>.html` keeps its own state. Migrates the legacy `'feature-impl-plan-data'` (used by the original pasted template's single-key layout) to the per-doc key on first load, then deletes the legacy entry.
- **featurePlan-inject.js** — reads JSON, escapes the title, and embeds the rest of the plan as a JSON literal (`INITIAL_DATA`) inside a `<script>` tag, escaping `</script>` breakout and the U+2028/U+2029 line-terminator characters that `JSON.stringify` leaves raw. `normalizePlan` applies per-section defaults via a single `ITEM_FIELD_DEFAULTS` table. Template path is optional.
- **featurePlan-inject.test.js** — unit tests for the injection script and template contract. Run with `node --test agents/skills/featurePlan/featurePlan-inject.test.js`. Covers escaping, script-breakout/line-terminator safety, default-filling for both top-level and per-section fields, and an end-to-end disk round-trip.

The instruction files that drive generation stay in each tool's directory (`claude/commands/featurePlan.md`, `copilot/skills/featurePlan/SKILL.md`): they're prose, not shared boilerplate, and differ in voice and path references. Both point at this folder's script and template by the same fixed `~/.agents/skills/featurePlan/` path.

## Extending

To add a new section: add its HTML container + add button + `bindAdd` call to the template with a `renderXxx()` function, then add the section key + per-field defaults to `ITEM_FIELD_DEFAULTS` in this folder's inject script, plus a test. The template and the script each hold one half of the per-section schema; both must evolve together, and both files contain a `NOTE` comment pointing at the other to keep them in sync. Finally, document the new JSON key in **both** `claude/commands/featurePlan.md` and `copilot/skills/featurePlan/SKILL.md` (they aren't shared). The AI's next generation picks up the new format.
