---
name: repo-template
description: Build a custom aicode-mcp template (scaffold.yaml, architect.yaml, RULES.yaml and liquid files) from the architecture and design patterns an existing brownfield repo already follows, so scaffold-mcp, architect-mcp and the aicode-mcp hooks keep new code consistent with it instead of imposing the generic dotnet-api or react-web templates. Use when the user asks to set up, create, generate, or customize templates, rules, scaffold methods, or architect patterns for a repo, or when the aicode-init hook says a repo has existing code and no template.
---

# repo-template

Builds `templates/<name>/` inside the target repo from the conventions its code already follows, then points the repo at it. The target repo is the session cwd unless the user names another. Default the name to `<repo>-<stack>`. Ask one question only if the stack is ambiguous (for example a repo holding both an API and a web app, where the user picks one or two templates).

Format references: `~/.local/share/aicode-mcp-dotnet/templates/dotnet-api` and `.../react-web`, installed by the dotfiles. Read them for the file format only. Never copy their patterns or rules into a brownfield template.

## 1. Learn the existing architecture

Read the repo, do not invent conventions. Collect:
- Stack, project layout, and the structure style: folder-per-feature, layers, clean architecture, MVC, and so on.
- Every file kind the repo creates repeatedly (controller, handler, service, repository, component, hook, test). For each kind, read 2 to 3 representative files and count how many files follow the same shape.
- Naming, DI registration, error handling, async, validation, mapping, test style, and forbidden patterns. Check lint config, `.editorconfig`, `CLAUDE.md`, `AGENTS.md`.

When files of one kind disagree, the dominant shape (the majority, or the newest code if the repo is clearly migrating) becomes the template. List the outliers for the user instead of encoding both.

## 2. Plan before writing

Show the user, in a few lines:
- the scaffold methods, one per file group the repo creates repeatedly, with the real example file each one is modelled on
- the architect patterns, one per file kind
- the rule groups, and the outliers from step 1

## 3. Write `templates/<name>/` in the target repo

Match the format of the reference templates exactly.

- `scaffold.yaml`
  - `features:` entries add a unit to the existing project. Add `boilerplate:` only if the repo really creates new projects of the same shape (for example a new microservice in a monorepo).
  - Each entry: `name`, `description`, `variables_schema` (JSON schema, `required`, `additionalProperties: false`), `includes`.
  - Include syntax: `"features/X.liquid->Path/{{ var }}/Out.ext"`. Append `?var=true` to make a file conditional on a boolean variable.
  - `exclude:` globs for files the scaffold must not own (csproj, appsettings, package.json, md).
- `features/*.liquid`: copied from the real representative files, with names and namespaces replaced by variables. Keep the real usings, base classes, attributes, and DI shape. Replace only method bodies with minimal stubs (`throw new NotImplementedException()` style).
- `architect.yaml`: `features:` list. Each has `name`, `design_pattern`, `includes` (globs relative to the project root that match the real files), `description`. One entry per file kind.
- `RULES.yaml`: `version: "1.0"`, `template: <name>`, `description`, then `rules:`.
  - First rule is a language-wide group with no `globs`, named like `csharp-general`.
  - Other rules have `pattern`, `globs` (`!` prefix excludes), `description`, `inherits`, and any of `must_do`, `must_not_do`, `should_do`, each a list of `- rule: <sentence>`.
  - Every rule must be checkable from code and backed by existing files that follow it. No generic advice the repo does not practise.

## 4. Wire it to the repo

- Write `.toolkit/settings.yaml` with `sourceTemplate: <name>` and `templatesPath: templates` (single project), or set `sourceTemplate` in each `project.json` (multi-project). If the file exists, change only `sourceTemplate`.
- Nothing else to install: the dotfiles register scaffold-mcp, architect-mcp and the Claude hooks user-wide. Do not create `.mcp.json`.

## 5. Verify with the tools

Do not claim done from reading the YAML.
1. `list-scaffolding-methods` (and `list-boilerplates` if any) shows the new methods.
2. `use-scaffold-method` into a scratch copy or a throwaway branch. Diff the output against the real example file it was modelled on, then build or type-check it. Delete the generated files afterwards.
3. `get-file-design-pattern` on 2 real files per kind returns the expected pattern.
4. `review-code-change` on a real file returns the matching rules, and the real file does not violate its own `must_do` or `must_not_do` rules. A violation means the rule is wrong for this repo. Fix the rule.

Report failures and fix the template, not the tools.
