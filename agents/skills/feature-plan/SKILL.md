---
name: feature-plan
description: Take a feature the user has in mind and turn it into a co-authored, code-level feature implementation plan (featurePlan-<slug>.html) — file-by-file change manifest in build order, pseudo-code, edge cases, and open questions the human decides, all grounded in this repo's actual code. The user resolves questions and edits sections in the browser; exported human edits are tagged and override the AI draft. Use when the user asks for a feature implementation plan, a code-level breakdown, or says "featurePlan".
---

# featurePlan: Feature implementation plan via JSON → HTML injection

Turn the user's feature into a **code-level implementation plan**: you generate structured JSON; `featurePlan-inject.js` injects it into the HTML template deterministically — you never rewrite the template. The user edits every section in the browser, then clicks **Copy AI-Ready Plan** and pastes the block back for implementation. This is the code-level step after the architectural `/arch` plan: one feature, file-by-file changes, pseudo-code, contracts, edge cases, tests.

**Prime directive:** every drafted section is pulled from the actual repo — file paths that exist or are the obvious place for new code, pattern choices matching this codebase's conventional stack, contracts grounded in existing controllers/services. No fabricated filler. Read the code the feature touches before proposing paths or patterns; never do web research.

**Co-author contract:** you draft, the human decides.
- Every ambiguity you cannot resolve from the ask or the code becomes an `openQuestions` item with options, never prose buried in `overview` or `solutionApproach`.
- The export tags human changes `[HUMAN-EDITED]` / `[HUMAN-ADDED]`; tagged content is authoritative over your draft.
- An `(UNRESOLVED …)` decision in the pasted plan is a blocker: ask the human to decide, do not implement past it.

---

## Operating modes

Derive `<slug>` from the feature name: a few words, lowercased, spaces→hyphens ("two-factor auth" → `two-factor-auth`).

**Mode A — Draft / update.** The user names a feature (no exported plan pasted).
1. Research the repo, then draft the sections defined below, applying the skip rules.
2. Save the JSON to `featurePlan-<slug>.json` (temporary).
3. Run `node ~/.agents/skills/feature-plan/featurePlan-inject.js featurePlan-<slug>.json featurePlan-<slug>.html`.
   If `featurePlan-<slug>.html` already exists, the same command **merges into it** (update-in-place: existing items keep their ids, same-id items take the new fields, new items append, browser-side human edits survive). Never delete or recreate an existing plan file, and never change its `title` on an update — retitling detaches the user's browser edits.
4. Delete the temporary JSON.

**Mode B — Implement.** The user pastes the **"Copy AI-Ready Plan"** export.
1. `[HUMAN-EDITED]` / `[HUMAN-ADDED]` tags override your original draft wherever they conflict.
2. Any `(UNRESOLVED …)` open question: stop and ask the human to decide first.
3. Implement strictly per the plan, file by file in manifest order — or revise sections and re-inject (Mode A step 3) if the design changed.

---

## Plan JSON

**Scalars:**
- `title` — short, slug-friendly feature name (no slashes/colons); becomes `<title>`/`<h1>`.
- `overview` — **free-form paragraph(s), your own words**: quote the user's ask (near-)verbatim, then explain what you understood — the goal, who it's for, and the existing code it plugs into (files, classes/services, DB tables). Be creative in how you tell it; be honest and specific about the repo. Ambiguities go to `openQuestions`, not here.
- `architecture` — **free-form, your own words**: the design pattern choices and the architecture as you see it. Prose plus an ASCII component/flow diagram is encouraged — show how the pieces connect, name the pattern(s) this repo actually uses, and call out any deliberate deviations ("no separate Repository for OTP — reuse UserRepository"). Grounded in one exemplifying file you actually read.
- `folderStructure` — **omit**; the inject script derives the tree from `files[]` (supply only to override).

**Sections** (arrays of items; each `id` is any unique string). *No redundancy:* each fact lives in exactly one section — an empty array is a statement, not a gap.

- `openQuestions` — `{ id, question, options, decision }`. One per unresolved ambiguity; `options` drafted one per line with a recommended one marked; `decision` **always empty in your draft** (empty exports as `(UNRESOLVED …)`).
- `solutionApproach` — `{ id, aspect, rationale }`. Settled design reasoning and trade-offs per decision area (Architecture, Integration, …); anything still open belongs in `openQuestions`.
- `acceptanceCriteria` — `{ id, criterion, testCase }`. Testable "done" conditions from the user's ask, each paired with the test case that proves it (test or concrete manual step).
- `files` — `{ id, order, action, path, description, pseudoCode }`. Ordered manifest of every file to create/update/delete. `action` ∈ { create, update, delete }; `order` is a positive integer reflecting build sequence (types before consumers, repository before service, schema before migration). `pseudoCode` is a real stub/signature copied verbatim as the implementation scaffold — new files get a stub, updated files only the changed surface.
- `logicSteps` — `{ id, step, pseudo }`. *Skip* (`[]`) unless orchestration spans multiple files beyond what `files[].pseudoCode` shows.
- `contracts` — `{ id, name, inputs, outputs }`. *Skip* unless a public entry point (route, CLI command, exported function) is added or changes signature. Concrete shapes, error responses included.
- `edgeCases` — `{ id, condition, handling }`. Validation rules, error returns, fallbacks — the scenarios typical for this kind of feature.

**Sparse example** (shape only — real plans carry full repo-grounded content):

```json
{
  "title": "Add two-factor authentication",
  "overview": "You asked to \"add 2FA to login\". I read AuthService.php and the users table; I understand this as a TOTP second factor verified at login, with enrollment from the profile page. Login currently goes password-only through AuthService::login().",
  "architecture": "Layered flow, one new service:\n\n  LoginController ──▶ AuthService ──▶ TotpService  [NEW]\n                          │\n                          └──▶ UserRepository\n\nTOTP logic is isolated in TotpService so AuthService stays thin. No separate Repository for OTP — reuse UserRepository.",
  "openQuestions": [
    { "id": "q-1", "question": "Enrollment mandatory at next login, or opt-in?", "options": "A) Mandatory (recommended)\nB) Opt-in from profile", "decision": "" }
  ],
  "files": [
    { "id": "f-1", "order": 1, "action": "create", "path": "src/Security/TotpService.php", "description": "TOTP enrollment + verification", "pseudoCode": "class TotpService {\n  public function enroll(User $user): string { /* generate secret */ }\n  public function verify(User $user, string $code): bool { /* check code */ }\n}" }
  ]
}
```

---

## Interactive mode

To let the user ask questions from inside the plan page: `node ~/.agents/skills/feature-plan/featurePlan-serve.js featurePlan-<slug>.html` — starts the listener, opens the browser (WSL-aware), and bridges questions/answers through `featurePlan-questions.jsonl` / `featurePlan-answers.jsonl` next to the plan. Full protocol: this folder's README.

---

## After saving

Print to chat:
1. The filename (`featurePlan-<slug>.html`).
2. One line per non-empty section ("openQuestions: 1, files: 4 (1 create, 3 update), …"); name any section skipped under the skip rules.
3. Next step: "Open the file, **decide the open questions**, edit any section directly in the browser, then click **Copy AI-Ready Plan** and paste the block back — your edits are tagged and override my draft; I'll implement strictly per the plan."

---

## Self-check (before saving)

- Every `files[].path` is an existing repo path (update/delete) or the conventional new location (create); paths and descriptions come from this repo, not invented.
- `files[].pseudoCode` is a real signature/stub, not "// TODO"; `files[].order` reflects build sequence.
- `overview` quotes the user's actual ask before your own explanation of what you understood.
- `architecture` names patterns this repo actually uses (read one exemplifying file first) and shows the design — a diagram beats a list of pattern names.
- `acceptanceCriteria` are checkable after implementation, not vague qualities; each has its proving `testCase`.
- Every unresolved ambiguity is an `openQuestions` item with options and an empty `decision`.
- `edgeCases` covers the scenarios typical for this feature type (auth: missing creds, bad creds, rate-limit).
- No section repeats another: `logicSteps` adds nothing the manifest shows, `contracts` only changed public surface, `folderStructure` absent.
- Updating an existing plan? Same output filename, same `title`, merged — never a fresh file.
