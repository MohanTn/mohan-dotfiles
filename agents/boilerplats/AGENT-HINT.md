## Boilerplate generator

For repository/controller/handler/validator/factory/commands/query/request/response/mapper/helper/di-injection boilerplate in csharp, typescript, javascript, python, or go (or script/function/validator/helper in sh), using the generator is MANDATORY, never hand-write it. Enforcement is deterministic and has no override: a PreToolUse hook blocks hand-written boilerplate by filename AND by content signature (renaming the file does not exempt it), blocks edits that hand-write a new member into a boilerplate file, and a Bash guard blocks shell-redirection writes to code files.

Preferred path — the scaffold MCP tools:

    scaffold_list                                    all languages and templates
    scaffold_describe { lang, template }             required/optional data fields, default marker
    scaffold_create   { lang, template, out, data }  new file
    scaffold_inject   { lang, template, out, data }  add a member to an existing file
    scaffold_adopt    { lang, out, anchor? }         marker only, no member

Every result contains the file type, the fillable line numbers, and the FULL numbered file content. NEVER re-read a file you just scaffolded — edit it directly from the returned lines.

### Greenfield — new file

`scaffold_create`, then fill in the logic with ordinary edits above the `scaffold:inject` marker.

### Brownfield — the file already exists

Use `scaffold_inject` exactly the same way, whether or not the file has ever been scaffolded. A legacy file with no marker is **adopted automatically**: the marker is placed at the end of the enclosing top-level block (inside the class for a class-shaped file, at module scope for a module-shaped one), then the member is injected above it. The result reports `adopted` and `markerLine` — check from the returned content that the marker landed in the scope you intended.

This is ongoing discovery, not a bootstrap: only the file you are working on is adopted, the rest of the codebase stays exactly as it was. Do not adopt files ahead of time, and never bulk-mark a tree.

- Marker in the wrong scope? Pass `anchor` — a 1-based line number, or a unique snippet the marker should precede.
- No safe anchor (minified, no enclosing block)? The call errors and writes nothing rather than guessing. Pass an explicit `anchor`.
- Changing the body of an existing member, renaming, refactoring inside a member: ordinary `Edit`, never blocked.

Fallback without MCP (same engine, same structured results with `--json`):

    node ~/.agents/boilerplats/scaffold.js --lang <lang> --template <name> --out <path> --data '<json>' [--inject] [--adopt] [--anchor '<line|snippet>'] [--json]

Missing required data fields are a hard error, nothing is written. The marker defaults per language (`# scaffold:inject` for python/sh, `// scaffold:inject` otherwise), no `--marker` needed. Templates live at `~/.agents/boilerplats/<lang>/<template>.hbs`; member templates are indentation-relative, so an injected member is re-indented to the marker's depth.

Never remove a `scaffold:inject` marker — the guard blocks edits and overwrites that drop it. The templates are intentionally generic starting points; run them, then correct and fill in whatever the skeleton got wrong.
