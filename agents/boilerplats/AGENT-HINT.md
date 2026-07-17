## Boilerplate generator

For repository/controller/handler/validator/factory/commands/request/response/mapper/helper/di-injection boilerplate in csharp, typescript, javascript, or python (or script/function/validator/helper in sh), use the generator instead of hand-writing it:

    node ~/.agents/boilerplats/scaffold.js --lang <lang> --template <name> --out <path> --data '<json>' [--inject --marker '<comment>']

Templates live at `~/.agents/boilerplats/<lang>/<template>.hbs`; each starts with a `{{!-- Data: {...} --}}` comment documenting the fields to pass via `--data`. Omit `--inject` to create a new file (fails if it already exists unless `--force`); pass `--inject` to insert generated content above a marker comment in an existing file, which stays in place so the same file can be injected again. The default marker is `// scaffold:inject`; python and sh templates use `# scaffold:inject` and require `--marker '# scaffold:inject'` to be passed explicitly.
