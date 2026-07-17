---
name: featurePlan
description: Take a feature the user has in mind and turn it into a code-level feature implementation plan (featurePlan-<slug>.html) — file-by-file change manifest in build order, business logic pseudo-code, function/API contracts, edge cases, and per-method tests, all grounded in this repo's actual code. The user edits each section in the browser and exports the plan back. Use when the user asks for a feature implementation plan, a code-level breakdown, or says "featurePlan".
---

# featurePlan: Feature implementation plan via JSON → HTML injection

Take a feature the user has in mind and turn it into a **code-level feature implementation plan**. You generate structured JSON; a deterministic script (`featurePlan-inject.js`) injects it into the HTML template — you never rewrite the template. The user edits every section in the browser (reordering files, refining pseudo-code, adding edge cases, etc.), then clicks **Copy AI-Ready Plan** and pastes the result back so the AI can implement.

This is the **code-level** step after the architectural-level `/arch` plan has pinned the system shape: where `/arch` drafts the architecture & solution plan (actors, containers, ADRs, roadmap), `/featurePlan` drills into a single feature with the file-by-file changes, pseudo-code, contracts, edge cases, and tests needed to build it.

**Prime directive:** every section gets a real draft pulled from the actual repo — file paths that exist or are the obvious place for new code, pattern choices that match the conventional stack in this codebase, contracts grounded in the existing controllers/services. Skip a section only when there's genuinely nothing grounded to seed; do not fabricate filler.

---

## Operating modes

**Mode A — First draft.** No `featurePlan-<slug>.html` exists in the working directory.
1. Research the repo (see below). Draft every section:
   - **Feature Overview** — title plus the target module, the user story, and a one-paragraph note on existing code this touches.
   - **Design Patterns & Overrides** — pin the layered + business-logic patterns, name any specific pattern choices (Repository vs DAO, Factory vs Builder), and any explicit overrides that deviate from the conventional approach.
   - **File Manifest** — ordered list of every file to create/update/delete, with a code-level stub or signature per file. Each item: `{ action, path, description, pseudoCode }`. Order reflects build sequence: types before consumers, repository before service, schema before migration.
   - **Logic Steps** — the orchestration in plain English + pseudo-code (one step per concern: validate → load → mutate → persist → return).
   - **Contracts** — entry points (controllers, handlers, CLI commands) with explicit inputs and outputs.
   - **Edge Cases** — validation rules, error returns, fallbacks.
   - **Tests** — one scenario per code unit (method or file).
2. Assemble JSON, save to `featurePlan-<slug>.json` (temporary).
3. Run `node ~/.agents/skills/featurePlan/featurePlan-inject.js featurePlan-<slug>.json featurePlan-<slug>.html`.
4. Delete the temporary JSON.

**Mode B — Refinement pass.** `featurePlan-<slug>.html` exists and the user pastes the doc's **"Copy AI-Ready Plan"** block.
1. Read the full exported plan. The pasted text contains every section and is the user's reviewed-and-edited source of truth.
2. Implement the feature strictly per the plan (file by file, in the order specified), or update sections and re-inject if the design changed.

**Derive `<slug>`** from the feature the user named: a few words, lowercased, spaces→hyphens (e.g. "two-factor auth" → `two-factor-auth`). Use `featurePlan-<slug>.html` as the file name.

---

## Before generating (research, don't guess)

- Read the actual code the feature touches before proposing file paths or pattern choices. Pull `path` and `description` from the repo — what files exist, where the new code should live, what conventions to follow.
- Never do web research; ground the plan in this repo.

---

## Top-level (`title`, `module`, `goal`, `context`)

- `title` — short feature name; goes into `<title>`, `<h1>`, and the Feature Overview card. Keep it slug-friendly (no slashes / colons).
- `module` — the high-level service / area this lives in (e.g. `User Service`, `Billing`, `Search`).
- `goal` — user story, "As a … I want … so that …". Free text in the Feature Overview card.
- `context` — the existing codebase context this feature plugs into: files that already exist, classes/services, DB tables/columns. The plan's effectiveness depends on this being honest and specific.

## Design patterns (`patternCore`, `patternBusiness`, `patternSpecific`, `patternOverrides`)

- `patternCore` — e.g. `Layered (Controller -> Service -> Repository)`, `MVC`, `Hexagonal`. One-line.
- `patternBusiness` — how the business logic is structured: `Transaction Script`, `Domain Model`, `Active Record`, etc.
- `patternSpecific` — the concrete in-codebase choices: which DAO pattern, which factory pattern, which DI style, which validation library. One paragraph.
- `patternOverrides` — *explicit* deviations ("No separate Repository for OTP — reuse UserRepository", "Use Singleton for CacheManager"). This is the field that lets the user deviate from the conventional pattern by editing one input.

The inject script falls back to the conventional `Layered (Controller -> Service -> Repository)` + `Transaction Script` defaults if you omit the patterns — fine when those genuinely match.

---

## Sections (`files`, `logicSteps`, `contracts`, `edgeCases`, `testScenarios`)

Each section is an array of items. Item shape per section:

- **files** — `{ id, order, action, path, description, pseudoCode }`. `action` ∈ { create, update, delete } (drives the on-page badge colour). `order` is a positive integer (the UI sorts ascending by it). `pseudoCode` is a code-level stub or signature; copy it verbatim as the scaffold when implementing. New files: emit a stub signature. Updated files: describe only the new/changed surface.
- **logicSteps** — `{ id, step, pseudo }`. One step per top-level concern (validate → load → mutate → persist → return), with plain-English + pseudo-code.
- **contracts** — `{ id, name, inputs, outputs }`. `name` is the route + method or the function signature; `inputs` and `outputs` are concrete shapes (request body schema, return type, error responses included).
- **edgeCases** — `{ id, condition, handling }`. `condition` is the scenario the test covers; `handling` is the expected behaviour in code terms.
- **testScenarios** — `{ id, target, scenario }`. `target` is `Class::method()` or `path/to/file.php`. `scenario` is the assertion in plain English.

---

## JSON Output Format

Write this to `featurePlan-<slug>.json`:

```json
{
  "title": "Feature name",
  "module": "Target module / service",
  "goal": "As a …, I want …, so that …",
  "context": "Existing User.php, AuthService.php, and a users table with columns id, email, password_hash.",
  "patternCore": "Layered (Controller -> Service -> Repository)",
  "patternBusiness": "Transaction Script",
  "patternSpecific": "Use Repository for User; Factory for OTP enrollment DTO.",
  "patternOverrides": "No separate Repository for OTP — reuse UserRepository.",
  "files": [
    {
      "id": "f-1",
      "order": 1,
      "action": "create",
      "path": "src/Security/TotpService.php",
      "description": "TOTP enrollment + verification",
      "pseudoCode": "class TotpService {\n  public function enroll(User $user): string { /* generate secret */ }\n  public function verify(User $user, string $code): bool { /* check code */ }\n}"
    },
    {
      "id": "f-2",
      "order": 2,
      "action": "update",
      "path": "src/Auth/AuthService.php",
      "description": "Wire TOTP into login flow",
      "pseudoCode": "public function login($email, $password, $code) { /* verify + then 2fa */ }"
    }
  ],
  "logicSteps": [
    { "id": "l-1", "step": "Validate credentials", "pseudo": "1. Check email format\n2. Look up user\n3. Verify password_hash" }
  ],
  "contracts": [
    { "id": "c-1", "name": "POST /api/v2/verify-2fa", "inputs": "{ userId: string, code: string }", "outputs": "{ ok: boolean, reason?: string }" }
  ],
  "edgeCases": [
    { "id": "e-1", "condition": "User has 2FA enabled but no code provided", "handling": "Return 401 with reason \"2fa_required\"." }
  ],
  "testScenarios": [
    { "id": "t-1", "target": "TotpService::enroll()", "scenario": "Returns a base32 secret that decodes to 20+ digits." },
    { "id": "t-2", "target": "AuthService::login() with bad code", "scenario": "Returns 401 and increments failed_2fa counter." }
  ]
}
```

`id` fields just need to be unique strings; any scheme works. `order` is a positive integer for files only (drives the on-page sort); other items don't need an order.

---

## After saving

Print to chat:
1. Filename (`featurePlan-<slug>.html`).
2. One line per non-empty section so the user knows what was drafted (e.g. "files: 4 (1 create, 3 update), logicSteps: 3, contracts: 2, edgeCases: 5, testScenarios: 6").
3. Next step: "Open the file, edit any section directly in the browser, then click **Copy AI-Ready Plan** and paste the block back — I'll implement strictly per the plan."

---

## 🔍 Self-check (before saving)

- Every file `path` references either an existing repo path (for `update`/`delete`) or a conventional new path (for `create`). Paths and `description`s are pulled from this repo, not invented.
- `files[].pseudoCode` is a real signature/stub, not "// TODO".
- `files[].order` reflects build sequence: types/repos before consumers, schema before migration, foundation before glue.
- `patternCore` / `patternBusiness` match what's actually used in this repo (read one file that exemplifies the convention before drafting).
- `edgeCases` enumerates scenarios typical for this kind of feature (auth: missing creds, bad creds, rate-limit). `testScenarios` map 1:1 to file changes, not to aspirational coverage.

---

## Implementation

1. `featurePlan-<slug>.html` exists? → Mode B, else Mode A.
2. **Mode A:** research the code, draft every section (8 scalar fields + 5 section arrays), save JSON, run `node ~/.agents/skills/featurePlan/featurePlan-inject.js featurePlan-<slug>.json featurePlan-<slug>.html`, delete JSON.
3. **Mode B:** read the pasted "Copy AI-Ready Plan" block, implement strictly per the plan, or revise sections and re-inject if the design changed.
4. Report per "After saving" (Mode A) or proceed to implementation (Mode B).
