# featurePlan: shared template + injection script + WebSocket AI integration

The common layer behind the `feature-plan` skill in Claude Code, Copilot CLI, and Pi: one HTML template, one Node.js injection script, WebSocket client for real-time AI chat, and a harness listener for bidirectional communication. All harnesses discover this directory at its fixed path (`agents/skills/feature-plan/` deployed to `~/.agents/skills/feature-plan/` via `nix/agents.nix`; `nix/claude.nix` also links it to `~/.claude/skills`). No harness keeps its own copy of the template or the inject script.

The new interactive mode allows users to ask clarifying questions about design decisions while editing the plan, with an AI agent responding in real-time and suggesting fine-grained patches to plan sections.

## What the document is for

`/featurePlan` produces a **co-authored feature implementation plan**: the AI drafts, the human decides. The AI seeds an editable HTML page (feature overview, open questions, design & architecture, solution approach, ordered file manifest, pseudo-code, acceptance criteria & tests, edge cases, contracts — redundant sections skipped, see below). The human resolves the **Open Questions**, edits any section in the browser, and exports via **Copy AI-Ready Plan**. The export diffs against the AI's original draft and tags human changes `[HUMAN-EDITED]` / `[HUMAN-ADDED]` so the implementing AI treats them as authoritative; an undecided open question exports as `UNRESOLVED` and blocks implementation. Everything persists per document via `localStorage` (key derived from `document.title`, so different `featurePlan-<slug>.html` files don't share state).

The on-page sections in order:

- **Feature Overview** — title plus one free-form paragraph in the AI's own words: the user's ask (near-verbatim), what the AI understood, and the existing code it touches.
- **Open Questions & Decisions** — ambiguities the AI couldn't resolve, each with drafted options and a human-owned `decision` field. Empty decision = `UNRESOLVED` in the export; the approval gate shows the unresolved count live.
- **Design Pattern & Architecture** — free-form: the AI explains its pattern choices and draws the architecture (prose + ASCII diagrams) as it sees it; the human edits to redirect.
- **Solution Approach & Rationale** — settled design decisions and trade-offs; anything still open lives in Open Questions instead.
- **Resulting Folder Structure** — ASCII tree derived by the inject script from the file manifest (`[CREATE]` / `[UPDATE]` / `[DELETE]` markers); the AI no longer authors it, the human can still edit it.
- **File Change Manifest (In Order of Execution)** — ordered list of files with `action` (create/update/delete), `path`, `description`, and `pseudoCode` per file. Sorted by a numeric `order` field; reorderable in the UI. The single source of truth for touched paths.
- **Acceptance Criteria & Test Cases** — testable "done" conditions, each paired with the test case that proves it.
- **Edge Cases & Error Handling** — what happens when things go wrong.
- **Core Business Logic (Detailed Pseudo-Code)** — *skippable:* only cross-file orchestration the manifest pseudo-code doesn't already show.
- **Function / API Contracts** — *skippable:* only new/changed public entry points.

Skippable sections keep each fact in exactly one place; the AI emits `[]` when another section already carries the content.

The **Export & Execution** card adds a **Copy AI-Ready Plan** button (full document as plain text, ready to paste into any coding AI) and a **Reset all data** button.

## Two-stage workflow

1. **Content (the AI).** Generates the plan as **structured JSON** — scalar fields (`title`, `overview`, `architecture`) and section arrays (`openQuestions`, `solutionApproach`, `acceptanceCriteria`, `files`, `logicSteps`, `contracts`, `edgeCases`). Cheap in tokens: no template boilerplate is regenerated, and `folderStructure` is derived from `files[]` (supply it only to override).
2. **Injection (the script).** `featurePlan-inject.js` merges that JSON into `featurePlan-template.html` deterministically, embedding it as the page's `INITIAL_DATA`. The AI never reads or rewrites the template. `INITIAL_DATA` doubles as the provenance baseline the export diffs against.

## Usage

### Standard (offline) mode
```bash
# First draft
/featurePlan add two-factor authentication

# Refinement: open the file, edit any section directly in the browser, click
# "Copy AI-Ready Plan", paste the block back so the AI can implement.
```

### Interactive mode (any harness: Claude Code, Copilot CLI, Pi)

One command starts the listener, opens the browser, and prints the URL:

```bash
node ~/.agents/skills/feature-plan/featurePlan-serve.js featurePlan-<slug>.html [--port 3001] [--no-open]
```

The launcher is harness-agnostic: instead of an in-process AI callback, it bridges through **JSONL files** in the plan's directory, so any agent that can run a shell command and read/write files can drive it:

- `featurePlan-questions.jsonl` — appended by the launcher, one object per question: `{ id, section, question, plan }`.
- `featurePlan-answers.jsonl` — appended by the AI harness: `{ id, response, patches?: [{ type: 'patch', section, itemId, field, value, action }] }`. The `id` must echo the question's; matching answers are broadcast to the page (response text + live patches).

Port handling: on `EADDRINUSE` the launcher walks up to 10 ports past the base. Unanswered questions time out after 10 minutes with a placeholder response.

**WSL:** the launcher detects WSL (`WSL_DISTRO_NAME` / `/proc/version`) and opens the Windows browser via `wslview`, falling back to `powershell.exe Start-Process`, translating the path with `wslpath -w`. The page's `ws://localhost:<port>` socket reaches the WSL server through WSL2's default localhost forwarding — if you disabled `localhostForwarding` in `.wslconfig`, the page degrades to static (offline) mode after its reconnect attempts.

Programmatic use (`aiAgent` callback) is still available via `featurePlan-harness-listener.js` — `createServer(port, { aiAgent })` — the launcher is a convenience wrapper around it.

User workflow in interactive mode:
1. Hover over any section header and click the **💬 Comment** button.
2. Side panel opens on the right; type a question (e.g., "Why singleton pattern?").
3. Click **Send**. The question is transmitted over WebSocket to the harness.
4. AI responds with clarification text and optional patch operations.
5. Plan sections update live in the browser.
6. Comments are stored locally in browser storage, not exported.
7. Continue editing and building the plan.

Manual injection (any harness, same path):

```bash
node ~/.agents/skills/feature-plan/featurePlan-inject.js featurePlan.json featurePlan.html
# The third (template-path) argument is optional; it defaults to
# featurePlan-template.html next to the script, so this also works from a checkout:
node agents/skills/feature-plan/featurePlan-inject.js featurePlan.json featurePlan.html
```

### Updating an existing plan (update-in-place)

When the output HTML already exists, the same inject command **merges** instead of replacing (`✓ Updated (merged)`): the embedded `INITIAL_DATA` is extracted, the incoming JSON is applied on top (same-id items take the new fields, unknown-id items append, sections absent from the input survive, non-empty scalars win), and the folder tree is re-derived from the merged manifest. An existing file without an `INITIAL_DATA` anchor (hand-edited) makes the command exit 1 with the file untouched.

Human browser edits live in `localStorage` (keyed by the document title), not in the file, so they survive re-injection. On load the template reconciles the new seed against stored data: genuinely new seed items appear, stored (human) values always win, and items the human deleted are not resurrected (a per-document `seen-seed-ids` record distinguishes "new from re-injection" from "deleted by human"). Because the storage key derives from the title, keep the title stable across updates — retitling detaches prior edits.

## JSON structure

Top-level keys: 3 scalar fields (`title`, `overview`, `architecture`) plus 7 section arrays. `folderStructure` is accepted but normally omitted (derived from `files[]`).

```json
{
  "title": "Add two-factor authentication",
  "overview": "You asked to \"add 2FA to login\". I read AuthService.php and the users table (id, email, password_hash); I understand this as a TOTP second factor verified at login, with enrollment managed from the profile page.",
  "architecture": "Layered flow, one new service:\n\n  LoginController ──▶ AuthService ──▶ TotpService  [NEW]\n                          │\n                          └──▶ UserRepository\n\nTOTP logic is isolated in TotpService so AuthService stays thin. No separate Repository for OTP — reuse UserRepository.",
  "openQuestions": [
    { "id": "q1", "question": "Is TOTP enrollment mandatory at next login, or opt-in from the profile page?", "options": "A) Mandatory at next login (recommended)\nB) Opt-in from profile settings", "decision": "" }
  ],
  "solutionApproach": [
    { "id": "s1", "aspect": "Architecture", "rationale": "Separate TOTP logic into its own service to keep auth concerns modular. This allows future 2FA methods (SMS, hardware keys) without touching AuthService." },
    { "id": "s2", "aspect": "Performance", "rationale": "Store TOTP secrets encrypted in the users table, not in a separate table. Reduces DB lookups during login; trade-off is we can't easily audit secret rotations, but we can log them in an audit table separately." }
  ],
  "acceptanceCriteria": [
    { "id": "a1", "criterion": "Given a user with 2FA enabled, when they log in without a code, then the login is rejected with reason 2fa_required.", "testCase": "Integration test on POST /login." }
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
  ]
}
```

Allowed select values: `files.action` ∈ { create, update, delete }. The script fills defaults for missing fields, so a sparse input still renders a valid page.

`id` fields just need to be unique strings; any scheme works. The inject script preserves `id` so the user's existing in-browser edits stay linked to the right item across re-injections, and coerces `files[].order` to a Number so the sort works on injected items too.

## Files

- **featurePlan-template.html** — the template with `{{FEATURE_TITLE}}` (for `<title>` and `<h1>`) and `{{INITIAL_DATA_JSON}}` markers. Renders every section entirely client-side from the injected data object. Uses `localStorage` key `'feature-impl-plan:' + document.title` so each `featurePlan-<slug>.html` keeps its own state. Migrates the legacy `'feature-impl-plan-data'` (used by the original pasted template's single-key layout) to the per-doc key on first load, then deletes the legacy entry. Keeps a `SEED` snapshot of `INITIAL_DATA` at load; the export compares against it to emit `[HUMAN-EDITED]` / `[HUMAN-ADDED]` provenance tags. **NEW:** Includes a side panel for inline comments/questions and real-time AI chat when launched via harness with `?socket-port=PORT`.
- **featurePlan-inject.js** — reads JSON, escapes the title, and embeds the rest of the plan as a JSON literal (`INITIAL_DATA`) inside a `<script>` tag, escaping `</script>` breakout and the U+2028/U+2029 line-terminator characters that `JSON.stringify` leaves raw. `normalizePlan` applies per-section defaults via a single `ITEM_FIELD_DEFAULTS` table and derives `folderStructure` from `files[]` when absent (`deriveFolderStructure`). Template path is optional. When the output HTML already exists, `extractInitialData` + `mergePlans` update it in place instead of replacing it. Exports `createPatch` and `createAddPatch` utilities for harness patch operations.
- **featurePlan-serve.js** — one-command interactive launcher: starts the harness listener (walking ports on `EADDRINUSE`), opens the browser (WSL-aware: `wslview` → `powershell.exe`, `wslpath -w` translation; `xdg-open` on Linux, `open` on macOS), and bridges questions/answers through the JSONL files described above.
- **featurePlan-socket-client.js** — WebSocket client for browser page. Manages connection to harness listener, sends user questions over socket, receives AI responses and patch operations, auto-reconnects on disconnect, queues messages when offline. Exports `FeaturePlanSocket` class for use in the template.
- **featurePlan-harness-listener.js** — WebSocket server for harness (Claude Code, Copilot, Pi). Listens for questions from the HTML page, forwards to an AI agent function, sends patch operations back to the page. Supports custom AI agent or defaults to a no-op echo. Broadcasts responses to all connected clients.
- **featurePlan-inject.test.js** — unit tests for the injection script and template contract. Run with `node --test featurePlan-inject.test.js`. Covers escaping, script-breakout/line-terminator safety, default-filling for both top-level and per-section fields, update-in-place merging, and end-to-end disk round-trips.
- **featurePlan-harness-listener.test.js** — unit tests for the WebSocket listener. Covers instantiation, server start/stop, AI agent integration.
- **featurePlan-serve.test.js** — unit tests for the launcher: platform detection, opener fallback, JSONL bridge round-trip (including malformed lines and timeouts), port walking, and a full socket round-trip through `serve()`.
- **package.json** — dependencies (ws for WebSocket). Run `npm install` before using the harness listener.

The instruction file that drives generation is this folder's `SKILL.md`; it points at the script and template by the fixed `~/.agents/skills/feature-plan/` path.

## Extending

To add a new section: add its HTML container + add button + `bindAdd` call to the template with a `renderXxx()` function and its field list in the export's `SECTION_FIELDS` (for provenance tagging), then add the section key + per-field defaults to `ITEM_FIELD_DEFAULTS` in this folder's inject script, plus a test. The template and the script each hold one half of the per-section schema; both must evolve together, and both files contain a `NOTE` comment pointing at the other to keep them in sync. Finally, document the new JSON key in `SKILL.md`. The AI's next generation picks up the new format.
