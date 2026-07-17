---
name: scaffold-use
description: Use the already-installed `scaffold` CLI (@mohantn/scaffold-core) inside any target repo to generate boilerplate — e.g. a .NET CRUD feature or endpoint — from a configured template pack. Use when the user wants to scaffold a new entity/endpoint/service/DTO in a repo that follows an existing target-stack pattern (dotnet, etc.), and only logic/business rules are left for the agent to fill in. Not for developing the CLI itself (see scaffold-cli-dev) or authoring a new template pack (see scaffold-pack-author).
---

# scaffold-use — drive `scaffold` in any repo

`scaffold` never calls an LLM. It renders Handlebars templates from a versioned **template pack** and injects marker-based boilerplate into existing files, then prints a report. Your only job is filling the `AI_IMPLEMENTATION` blocks it flags empty — the business logic. Don't hand-write boilerplate the CLI could render.

## 0. Binary and pack location — check these first

- **Binary**: `scaffold --version` (global install) or `npx -y @mohantn/scaffold-core --version` (no install). Either form works everywhere below; substitute freely.
- **Pack**: the published npm package ships **only** `dist/` + `hooks/` — no template packs (`package.json`'s `files` list has no `templates/`). A pack is a local directory on disk; `scaffold init --pack` rejects git URLs outright. You need a filesystem path to an actual pack, e.g. this repo's vendored `templates/templates-dotnet` (single version today: `csharp-enterprise`) from a local checkout of `scaffold-toolkit`, or a pack the target repo's own `scaffold-pack-author` run produced under its own `templates/`. If neither exists, this skill can't proceed — point the user at `scaffold pack new` / the `scaffold-pack-author` skill instead of inventing boilerplate by hand.

## 1. One-time setup per target repo

```bash
cd <target-repo>
scaffold init --pack backend=<absolute-path-to-pack>/templates-dotnet@csharp-enterprise
```

Writes `.scaffold/config.json`: `{ projectType, packs: { backend: { path, version } } }`. `--project-type` is auto-detected if omitted; `--pack name=path@version` is repeatable for multiple stacks (e.g. `backend=...` and `frontend=...`). Re-run isn't needed unless the pack path/version changes.

**Repo-wide defaults** (skip repeating `--combine`, `database.provider`, etc. every call): hand-edit `.scaffold/config.json`'s pack entry to add `"defaults": { "options": { "combine": true, "database": { "provider": "postgres" } } }` — merges under every manifest for that slot; explicit flags still win.

**Brownfield repo** (existing hand-written code the pack should now own): after `init`, run `scaffold bootstrap-markers --dry-run`, review, then without `--dry-run`. Placed markers may need `needsManual` entries done by hand — the report says which.

## 2. Generate boilerplate — prefer `scaffold add`

Entity-first, no manifest authoring needed. Every subcommand takes `--dry-run --force --json --format doc --template-set <slot>` (slot only needed if >1 pack configured).

| Command | Use for |
|---|---|
| `scaffold add feature --name Product --properties "Name:string,Price:decimal,IsActive:bool"` | Full CRUD: entity, DTO, repo, controller, commands/queries+handlers+validators, DI wiring. Add `--operations Create,Read` to narrow, `--combine` for single-file repo, `--db Tenant` for scoped DB. |
| `scaffold add custom --name GetProductsWithFilter --return-type PagedResult --parameters "page:int,pageSize:int" --target-controller ProductsController` | One query/command injected into an existing controller+repository. `--is-command` for a mutation, `--method`/`--route` to override. |
| `scaffold add domain-event --name ProductCreated --entity Product` | Domain event record + handler stub. |
| `scaffold add factory --entity Product` | Domain factory + DI registration. |
| `scaffold add helper --name guard\|crypto` | Utility class. |
| `scaffold add cloud-provider --provider aws\|azure\|gcp` | Storage provider abstraction + implementation. |
| `scaffold add scheduler-job --name NightlyCleanup --scheduler quartz\|hangfire` | Background job. |
| `scaffold add health-check --name Database` | Health check + `/health` registration. |
| `scaffold add outbox-processor` | Outbox entity + dispatcher. |

Run with `--dry-run --format doc` first if unsure — same code path as a real run, human-readable preflight, zero disk writes.

**Extending** an existing entity/controller: re-run the same `add` command with the new fields/operation. Existing `AI_IMPLEMENTATION` content and markers are untouched (hash-trailer idempotency) — never pass `--force` unless you intend to discard a prior implementation.

## 3. Low-level path (only when `add` doesn't fit)

```bash
scaffold manifest new --stack backend --entity Invoice --field Amount:decimal --field DueDate:DateTime --out invoice.manifest.json
scaffold generate --manifest invoice.manifest.json --dry-run --format doc   # preflight
scaffold generate --manifest invoice.manifest.json                          # real run
```

`--option path=value` sets manifest options, `--artifact <tag>` scopes to specific descriptor-tagged entries (artifact-scoped packs like `csharp-enterprise` require this — pass every artifact tag the target pack expects, e.g. `--artifact base --artifact op-create`).

## 4. Read the report, fill `AI_IMPLEMENTATION` blocks

The report (TOON by default, `--json` for JSON) has `created[]`, `injected[]`, `aiImplementation[]`, `changesetId`. For every `aiImplementation` entry with `empty: true`:

- Use Edit with `old_string` = the entry's `content` field (the exact current placeholder interior) and write the real implementation. More robust than `startLine`/`endLine`, which can drift.
- **Never touch an entry with `empty: false`** — that's either your prior work or the pack's shipped default; overwriting it destroys real code.
- If lost mid-task or after context got compacted: `scaffold next` (or `--json`) reprints every still-open block with its placeholder, no need to re-read generated files.

When done, confirm with:

```bash
scaffold status --json   # exit 0 + resolvedAll:true + empty unresolved[] means fully done
```

## 5. Undo

`scaffold undo <changesetId>` (printed in the generate report) reverts that run — deletes created files, restores modified ones. Refuses if a later changeset touched the same file (undo that one first) or if the file changed since (hash mismatch — pass `--force` to discard those edits knowingly).

## Common errors

| Message | Fix |
|---|---|
| `no pack configured for targetStack "X"` | `.scaffold/config.json` has no `packs.X` — check `--template-set`/`--stack` matches a configured slot. |
| `pack "X" has not been synced yet` | Only for `url`-based packs (rare now) — run `scaffold templates sync`. Path-based packs never hit this. |
| `template pack version "X" not found at <dir>` | Wrong `--pack`/version at `init` time, or the pack directory moved. |
| `marker "X" content differs from what was previously injected — refusing without --force` | Someone hand-edited a `SCAFFOLD:<marker>` region, or the manifest/template changed. Don't blind-`--force`; ask what's intended. |
| `<file> already exists and its target mode is "create"` | The pack's own bug (should be `skip-if-exists`/`overwrite`) — not something a flag fixes. |
| `scaffold status` exits non-zero | `unresolved[]` lists remaining blocks — go fill them. |

## What not to do

- Don't hand-write a file that `scaffold add`/`generate` would render — re-run the command instead, even for a one-field tweak.
- Don't edit inside a `SCAFFOLD:<marker>` region by hand — that's injector-owned; only `AI_IMPLEMENTATION_START/END` interiors are yours.
- Don't pass `--force` reflexively to make an error go away — it's the one flag that can silently discard real work.
- Don't invent a manifest field the pack doesn't declare (check `scaffold add <cmd> --help` or the pack's `manifest.templates.json` `inputs[]` first).
