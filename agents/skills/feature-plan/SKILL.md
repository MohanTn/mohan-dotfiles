---
name: feature-plan
description: Take a feature the user has in mind and turn it into a co-authored, code-level feature implementation plan (featurePlan-<slug>.html) — file-by-file change manifest in build order, pseudo-code, edge cases, and open questions the human decides, all grounded in this repo's actual code. The user resolves questions and edits sections in the browser; exported human edits are tagged and override the AI draft. Use when the user asks for a feature implementation plan, a code-level breakdown, or says "featurePlan".
---

# featurePlan: Feature implementation plan via JSON → HTML injection

Take a feature the user has in mind and turn it into a **code-level feature implementation plan**. You generate structured JSON; a deterministic script (`featurePlan-inject.js`) injects it into the HTML template — you never rewrite the template. The user edits every section in the browser (reordering files, refining pseudo-code, adding edge cases, etc.), then clicks **Copy AI-Ready Plan** and pastes the result back so the AI can implement.

This is the **code-level** step after the architectural-level `/arch` plan has pinned the system shape: where `/arch` drafts the architecture & solution plan (actors, containers, ADRs, roadmap), `/featurePlan` drills into a single feature with the file-by-file changes, pseudo-code, contracts, edge cases, and tests needed to build it.

**Prime directive:** every drafted section is pulled from the actual repo — file paths that exist or are the obvious place for new code, pattern choices that match the conventional stack in this codebase, contracts grounded in the existing controllers/services. Do not fabricate filler.

**Co-author contract:** the plan is a shared document — you draft, the human decides. Rules:
- Every ambiguity you cannot resolve from the ask or the code becomes an `openQuestions` item with options, never prose buried in `intent` or `solutionApproach`.
- The export tags human changes `[HUMAN-EDITED]` / `[HUMAN-ADDED]`. In Mode B, tagged content is authoritative over your original draft.
- An `(UNRESOLVED …)` decision in the pasted plan is a blocker: ask the human to decide, do not implement past it.

**No redundancy:** each fact lives in exactly one section. An empty array is a statement ("nothing beyond the manifest"), not a gap. Skip rules:
- `logicSteps` — only when orchestration spans multiple files beyond what `files[].pseudoCode` already shows; otherwise emit `[]`.
- `contracts` — only when a public entry point (route, CLI command, exported function) is added or its signature changes.
- `testScenarios` — only scenarios not already 1:1 with an `acceptanceCriteria` verification.
- `folderStructure` — never author it; the inject script derives the tree from `files[]`.

---

## Operating modes

**Mode A — First draft.** No `featurePlan-<slug>.html` exists in the working directory.
1. Research the repo (see below). Draft the sections (respecting the skip rules above):
   - **Feature Overview** — title plus the target module, the captured intent (user's ask verbatim + what you inferred), the user story, and a one-paragraph note on existing code this touches.
   - **Open Questions** — one item per unresolved ambiguity, with drafted options; `decision` stays empty for the human.
   - **Acceptance Criteria** — testable conditions that define "done", each with how to verify it. Pull these from the user's ask; every criterion must be checkable after implementation.
   - **Design Patterns & Overrides** — pin the layered + business-logic patterns, name any specific pattern choices (Repository vs DAO, Factory vs Builder), and any explicit overrides that deviate from the conventional approach.
   - **File Manifest** — ordered list of every file to create/update/delete, with a code-level stub or signature per file. Each item: `{ action, path, description, pseudoCode }`. Order reflects build sequence: types before consumers, repository before service, schema before migration. (The folder-structure tree is derived from this — don't write it.)
   - **Logic Steps** *(skippable)* — cross-file orchestration in plain English + pseudo-code, only what the manifest pseudo-code doesn't show.
   - **Contracts** *(skippable)* — new/changed public entry points with explicit inputs and outputs.
   - **Edge Cases** — validation rules, error returns, fallbacks.
   - **Tests** *(skippable)* — only scenarios beyond the acceptance-criteria verifications.
2. Assemble JSON, save to `featurePlan-<slug>.json` (temporary).
3. Run `node ~/.agents/skills/featurePlan/featurePlan-inject.js featurePlan-<slug>.json featurePlan-<slug>.html`.
4. Delete the temporary JSON.

**Mode B — Refinement pass.** `featurePlan-<slug>.html` exists and the user pastes the doc's **"Copy AI-Ready Plan"** block.
1. Read the full exported plan. `[HUMAN-EDITED]` / `[HUMAN-ADDED]` tags mark the human's changes — they override your original draft wherever they conflict.
2. If any open question reads `(UNRESOLVED …)`, stop and ask the human to decide; do not implement past it.
3. Implement the feature strictly per the plan (file by file, in the order specified), or update sections and re-inject if the design changed.

**Derive `<slug>`** from the feature the user named: a few words, lowercased, spaces→hyphens (e.g. "two-factor auth" → `two-factor-auth`). Use `featurePlan-<slug>.html` as the file name.

---

## Before generating (research, don't guess)

- Read the actual code the feature touches before proposing file paths or pattern choices. Pull `path` and `description` from the repo — what files exist, where the new code should live, what conventions to follow.
- Never do web research; ground the plan in this repo.

---

## Top-level (`title`, `module`, `intent`, `goal`, `context`)

- `title` — short feature name; goes into `<title>`, `<h1>`, and the Feature Overview card. Keep it slug-friendly (no slashes / colons).
- `module` — the high-level service / area this lives in (e.g. `User Service`, `Billing`, `Search`).
- `intent` — intent capture: the user's original ask quoted (near-)verbatim, then what you inferred from it. Lets the user correct a misread before anything is built. Ambiguities do not go here — they go to `openQuestions`.
- `goal` — user story, "As a … I want … so that …". Free text in the Feature Overview card.
- `context` — the existing codebase context this feature plugs into: files that already exist, classes/services, DB tables/columns. The plan's effectiveness depends on this being honest and specific.
- `folderStructure` — **omit.** The inject script derives the ASCII tree (with `[CREATE]` / `[UPDATE]` / `[DELETE]` markers) from `files[]`; supply it only to override the derived tree.

## Design patterns (`patternCore`, `patternBusiness`, `patternSpecific`, `patternOverrides`)

- `patternCore` — e.g. `Layered (Controller -> Service -> Repository)`, `MVC`, `Hexagonal`. One-line.
- `patternBusiness` — how the business logic is structured: `Transaction Script`, `Domain Model`, `Active Record`, etc.
- `patternSpecific` — the concrete in-codebase choices: which DAO pattern, which factory pattern, which DI style, which validation library. One paragraph.
- `patternOverrides` — *explicit* deviations ("No separate Repository for OTP — reuse UserRepository", "Use Singleton for CacheManager"). This is the field that lets the user deviate from the conventional pattern by editing one input.

The inject script falls back to the conventional `Layered (Controller -> Service -> Repository)` + `Transaction Script` defaults if you omit the patterns — fine when those genuinely match.

---

## Sections (`openQuestions`, `solutionApproach`, `acceptanceCriteria`, `files`, `logicSteps`, `contracts`, `edgeCases`, `testScenarios`)

Each section is an array of items. Item shape per section:

- **openQuestions** — `{ id, question, options, decision }`. One item per ambiguity you could not resolve. `question` is what the human must decide; `options` is your drafted choices (one per line, mark a recommended one); `decision` is **always empty in your draft** — the human fills it in the browser, and an empty decision exports as `(UNRESOLVED …)`.
- **solutionApproach** — `{ id, aspect, rationale }`. Explain the solution before implementation. `aspect` is a key decision area (e.g. "Architecture", "Integration", "Performance", "Error Handling"); `rationale` is the reasoning, trade-offs, and high-level explanation. Settled reasoning only — anything still open belongs in `openQuestions`.
- **acceptanceCriteria** — `{ id, criterion, verification }`. `criterion` is a testable "done" condition (Given/When/Then or a plain statement); `verification` is how to check it (which test, which manual step). The feature is done only when every criterion passes.
- **files** — `{ id, order, action, path, description, pseudoCode }`. `action` ∈ { create, update, delete } (drives the on-page badge colour). `order` is a positive integer (the UI sorts ascending by it). `pseudoCode` is a code-level stub or signature; copy it verbatim as the scaffold when implementing. New files: emit a stub signature. Updated files: describe only the new/changed surface.
- **logicSteps** — `{ id, step, pseudo }`. *Skippable:* only cross-file orchestration the manifest pseudo-code doesn't already show (validate → load → mutate → persist → return).
- **contracts** — `{ id, name, inputs, outputs }`. *Skippable:* only new/changed public entry points. `name` is the route + method or the function signature; `inputs` and `outputs` are concrete shapes (request body schema, return type, error responses included).
- **edgeCases** — `{ id, condition, handling }`. `condition` is the scenario the test covers; `handling` is the expected behaviour in code terms.
- **testScenarios** — `{ id, target, scenario }`. *Skippable:* only scenarios not already 1:1 with an acceptance criterion's verification. `target` is `Class::method()` or `path/to/file.php`. `scenario` is the assertion in plain English.

---

## JSON Output Format

Write this to `featurePlan-<slug>.json`:

```json
{
  "title": "Feature name",
  "module": "Target module / service",
  "intent": "User asked: \"add 2FA to login\". Inferred: TOTP second factor verified at login; enrollment managed from the profile page.",
  "goal": "As a …, I want …, so that …",
  "context": "Existing User.php, AuthService.php, and a users table with columns id, email, password_hash.",
  "patternCore": "Layered (Controller -> Service -> Repository)",
  "patternBusiness": "Transaction Script",
  "patternSpecific": "Use Repository for User; Factory for OTP enrollment DTO.",
  "patternOverrides": "No separate Repository for OTP — reuse UserRepository.",
  "openQuestions": [
    { "id": "q-1", "question": "Is TOTP enrollment mandatory at next login, or opt-in from the profile page?", "options": "A) Mandatory at next login (recommended — matches the security ask)\nB) Opt-in from profile settings", "decision": "" }
  ],
  "solutionApproach": [
    { "id": "s-1", "aspect": "Architecture", "rationale": "We're using a three-tier layered approach with a dedicated Service layer. This keeps auth logic decoupled from HTTP routing and allows reuse across CLI and API endpoints. Trade-off: adds a thin Service abstraction layer." },
    { "id": "s-2", "aspect": "Integration", "rationale": "TOTP enrollment happens at the User level, not during login. This allows users to set up 2FA at any time, not just at signup, and we can support multiple 2FA methods (TOTP, SMS) in the future." }
  ],
  "acceptanceCriteria": [
    { "id": "a-1", "criterion": "Given a user with 2FA enabled, when they log in without a code, then the login is rejected with reason 2fa_required.", "verification": "Integration test on POST /login." },
    { "id": "a-2", "criterion": "A user can enroll in TOTP from their profile and the secret round-trips through an authenticator app.", "verification": "Manual check with an authenticator app against the enrollment QR." }
  ],
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
    { "id": "l-1", "step": "Login orchestration across AuthService and TotpService", "pseudo": "1. Verify password (AuthService)\n2. If user.totp_secret set: require code, call TotpService.verify\n3. On success issue session; on failure return 2fa_required" }
  ],
  "contracts": [
    { "id": "c-1", "name": "POST /api/v2/verify-2fa", "inputs": "{ userId: string, code: string }", "outputs": "{ ok: boolean, reason?: string }" }
  ],
  "edgeCases": [
    { "id": "e-1", "condition": "User has 2FA enabled but no code provided", "handling": "Return 401 with reason \"2fa_required\"." }
  ],
  "testScenarios": [
    { "id": "t-1", "target": "TotpService::enroll()", "scenario": "Returns a base32 secret that decodes to 20+ digits." }
  ]
}
```

`id` fields just need to be unique strings; any scheme works. `order` is a positive integer for files only (drives the on-page sort); other items don't need an order. Note what the example skips: no `folderStructure` (derived), `logicSteps` only because the flow spans two services, and a single `testScenarios` item because the other scenarios are already acceptance-criteria verifications.

---

## After saving

Print to chat:
1. Filename (`featurePlan-<slug>.html`).
2. One line per non-empty section so the user knows what was drafted (e.g. "openQuestions: 1, solutionApproach: 2, acceptanceCriteria: 3, files: 4 (1 create, 3 update), edgeCases: 5"); name any section skipped under the no-redundancy rules.
3. Next step: "Open the file, **decide the open questions**, edit any section directly in the browser, then click **Copy AI-Ready Plan** and paste the block back — your edits are tagged and override my draft; I'll implement strictly per the plan."

---

## 🔍 Self-check (before saving)

- Every file `path` references either an existing repo path (for `update`/`delete`) or a conventional new path (for `create`). Paths and `description`s are pulled from this repo, not invented.
- `files[].pseudoCode` is a real signature/stub, not "// TODO".
- `files[].order` reflects build sequence: types/repos before consumers, schema before migration, foundation before glue.
- `patternCore` / `patternBusiness` match what's actually used in this repo (read one file that exemplifies the convention before drafting).
- `edgeCases` enumerates scenarios typical for this kind of feature (auth: missing creds, bad creds, rate-limit).
- `intent` quotes the user's actual ask before the inferred reading; don't paraphrase away the original words.
- `acceptanceCriteria` are checkable after implementation (a test or a concrete manual step), not vague qualities ("works well").
- Every unresolved ambiguity is an `openQuestions` item with options and an empty `decision` — none hides as prose in `intent` or `solutionApproach`.
- No section repeats another: `logicSteps` adds nothing the manifest pseudo-code shows, `testScenarios` duplicates no acceptance verification, `contracts` only covers changed public surface, `folderStructure` is absent (derived).

---

## Implementation

1. `featurePlan-<slug>.html` exists? → Mode B, else Mode A.
2. **Mode A:** research the code, draft the sections (9 scalar fields + 8 section arrays, applying the skip rules), save JSON, run `node ~/.agents/skills/featurePlan/featurePlan-inject.js featurePlan-<slug>.json featurePlan-<slug>.html`, delete JSON.
3. **Mode B:** read the pasted "Copy AI-Ready Plan" block; honor `[HUMAN-EDITED]`/`[HUMAN-ADDED]` tags as authoritative; stop on any `(UNRESOLVED …)` decision; implement strictly per the plan, or revise sections and re-inject if the design changed.
4. Report per "After saving" (Mode A) or proceed to implementation (Mode B).
