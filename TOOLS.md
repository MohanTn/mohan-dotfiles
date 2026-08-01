# Tool Inventory

What this repo installs and configures, grouped by role. Source of truth is
`nix/*.nix`; opt-in toggles are written by `./setup-packages.sh` into
`~/.config/mohan-dotfiles/packages-config.nix` (default: all off, see
`nix/default-packages-config.nix`).

---

## 1. Search, files, data

| Tool | Where | Why it is here |
| --- | --- | --- |
| `ripgrep` | packages.nix | Telescope live-grep, every agent search path |
| `fd` | packages.nix | Telescope file finder, agent file discovery |
| `jq` | packages.nix | Every Claude Code hook parses its JSON payload with it |
| `bat` | packages.nix | Paged file viewing with syntax highlight |
| `tree` | packages.nix | Quick directory shape |
| `universal-ctags` | packages.nix | `session-start.sh` builds `.claude/repo-map.md` from it |

## 2. Shell

| Tool | Where | Why it is here |
| --- | --- | --- |
| `zsh` | zsh.nix | Login shell, 50k shared history |
| `zinit` | zsh.nix | Plugin manager, core script from the Nix store (no self-clone) |
| `zsh-completions`, `fzf-tab`, `zsh-autosuggestions`, `zsh-history-substring-search`, `zsh-syntax-highlighting` | zsh.nix | Completion and interaction layer |
| `oh-my-posh` | packages.nix + zsh.nix | Prompt, catppuccin-mocha theme (`zsh/oh-my-posh-catppuccin-mocha.omp.json`) |
| `fzf` | zsh.nix | Ctrl-R history, Ctrl-T file search |
| `zoxide` | zsh.nix | `z` frecency jump, `zi` interactive pick |
| `wl-clipboard` | packages.nix | Bridges tmux copy-mode to the system clipboard |

Aliases of note: `cc` (Claude with the lean system prompt + tool allowlist),
`copilot` (Copilot CLI with its own allowlist), `repo`, `ls`.

## 3. Terminal, multiplexer, fonts

| Tool | Where | Why it is here |
| --- | --- | --- |
| `alacritty` | alacritty.nix | GPU terminal (needs nixGL on this box) |
| `ptyxis` | ptyxis.nix | GNOME/container terminal, often the real foreground one |
| `tmux` | tmux.nix | vi keys, mouse, base index 1, 10k scrollback |
| `tmuxPlugins.sensible`, `vim-tmux-navigator`, `catppuccin`, `tmux-nerd-font-window-name` | tmux.nix | Status bar, pane nav, per-window icons |
| `nerd-fonts.jetbrains-mono`, `nerd-fonts.symbols-only` | packages.nix | Glyphs for tmux status and agent icons; symbols-only is the fallback for broken Powerline codepoints |

## 4. Editor

| Tool | Where | Why it is here |
| --- | --- | --- |
| `neovim` | nvim.nix | Default editor, `vi`/`vim` aliases |
| kickstart.nvim (vendored `nvim/`) | nvim.nix | lazy.nvim config with C#/TypeScript LSP added; plugins install at runtime under `~/.local/share/nvim` |

## 5. Version control and forges

| Tool | Where | Why it is here |
| --- | --- | --- |
| `git` | git.nix | Enabled always; identity is opt-in (`enableGitConfig`) |
| `gh` | packages.nix | GitHub CLI |
| `glab` | packages.nix | GitLab CLI |
| `hunkdiff` (npm) | packages.nix activation | Interactive hunk-by-hunk diff review for code review |

## 6. Language toolchains

| Tool | Where | Why it is here |
| --- | --- | --- |
| `nodejs_22` | packages.nix | LSP extras, pi extensions, npm global CLIs |
| `pnpm` | packages.nix | enriched_planning |
| `python3` | packages.nix | `statusline-usage.py`, `session-analytics.py` |
| `gcc`, `gnumake` | packages.nix | Treesitter parser builds |
| `dotnet-sdk_8` | packages.nix | C# work |

## 7. AI coding agents

| Tool | Where | Why it is here |
| --- | --- | --- |
| Claude Code | claude.nix | Native installer (keeps self-updating); config, hooks, skills, statusline linked from repo |
| Pi | pi.nix | npm installer; `AGENTS.md`, `SYSTEM.md`, `APPEND_SYSTEM.md`, TS hook port, sandbox extension |
| GitHub Copilot CLI | optional-packages.nix (`enableGitHubCopilot`) | npm installer; hooks in `copilot/hooks` |
| little-coder + `llama-cpp` | little-coder.nix (`enableLittleCoder`) | Local Gemma GGUF via `llama-server`; Vulkan build under `littleCoderGpu` |
| `bubblewrap`, `socat` | packages.nix | Claude Code Bash sandbox and its network relay |

## 8. Agent support layer (repo-local, not packages)

| Thing | Where | Role |
| --- | --- | --- |
| `agents/AGENTS.md`, `agents/lean-system-prompt.md` | agents.nix | Tool-agnostic instructions shared by all three agents |
| `agents/boilerplats` (`scaffold.js`, `mcp-server.js`, hbs templates for 7 languages) | agents.nix + claude.nix | Boilerplate generator, registered as the user-scope `scaffold` MCP server |
| `agents/skills/` (`chrome-devtools-axi`, `feature-plan`, `frontend-design`, `graphify`, `repo-map-check`, `sketch-design`) | agents.nix | Discovered by Claude (`~/.claude/skills`), Copilot, and Pi (`~/.agents/skills`) |
| `claude/hooks/` (15 scripts) | claude.nix | Guardrails: secret-guard, boilerplate guards, goal capture, loop breaker, session start/end, context augment |
| `copilot/hooks/`, `pi/agent/extensions/hooks` | copilot.nix, pi.nix | Ports of the same policy to the other two harnesses |

## 9. System, ops, misc

| Tool | Where | Why it is here |
| --- | --- | --- |
| `htop` | packages.nix | Process view |
| `curl`, `wget`, `unzip` | packages.nix | Fetch/unpack in activations and by hand |
| `wslu` | packages.nix | `wslview` and friends, harmless on plain Linux |
| Google Chrome | setup.sh (`ensure_google_chrome`) | Backing browser for the chrome-devtools skill |
| `tools-maintenance` systemd user timer | maintenance.nix | Daily 02:00: npm update/prune/cache clean, HM generation expiry, `nix-collect-garbage -d 7d` |
| Homebrew | homebrew.nix (`enableHomebrew`) | Escape hatch for formulae nixpkgs lacks; `brewPackages` is idempotent |
| Docker + Compose | optional-packages.nix (`enableDocker`) | Container work |
| Python dev tools (`poetry`, `pip-tools`) | optional-packages.nix (`enablePython`) | Python projects |
| `pipeline-worker` | optional-packages.nix (`enablePipelineWorker`) | Agent pipeline runner, env in zsh.nix |
| LocalScribe | optional-packages.nix (`enableLocalScribe`) | Installed from GitHub releases to `~/.local/bin` |

## 10. Build and CI

| Tool | Where | Why it is here |
| --- | --- | --- |
| Nix flake, home-manager 25.05 | flake.nix, home.nix | The whole install mechanism; nixpkgs-unstable overlay for llama.cpp |
| `nix flake check` suite | flake.nix | home eval, hook selftests, docker hook parity, context-augment, feature-plan, prompt width, llama-server GPU |
| `shellcheck` | flake.nix checks only | Lints hook and helper scripts in CI, **not** in `home.packages` |
| GitHub Actions `ci.yml` | .github/workflows | Runs `nix flake check --impure` + a node job |
| `docker/` sandbox | docker-compose.yml, Dockerfile | Disposable containers running claude/copilot/pi with permissions pre-bypassed |

---

# Suggested additions

Ranked by how directly they serve work this repo already does.

## High value — closes a gap this repo demonstrably has

| Tool | Use case here |
| --- | --- |
| `shellcheck`, `shfmt` | Already a `flake.nix` check dependency, but not installed, so you cannot lint a hook locally before pushing. Add both to `packages.nix` and format the 15 `claude/hooks` scripts consistently. |
| `nix-output-monitor` (`nom`), `nvd` | `./setup.sh` prints a wall of build output and no diff. `nom` makes a switch readable; `nvd diff-closure` shows exactly what a generation changed, which is the missing feedback loop for `maintenance.nix`'s daily GC. |
| `direnv` + `nix-direnv` | Per-project toolchains without polluting `home.packages`. This is the standard answer for the `dotnet-sdk_8`/`pnpm`-style entries that only matter inside one repo. |
| `sops-nix` or `age` | `~/.zshrc.local` currently holds `PIPELINE_WORKER_GITHUB_TOKEN` in plaintext outside version control. `sops` lets the secret be committed encrypted and decrypted at activation, which also pairs with the existing `secret-guard.sh` hook. |
| `gitleaks` | `secret-guard.sh` blocks credential patterns at agent invoke time; `gitleaks` covers the other direction (a full repo/history scan, plus a CI job) so the guard is not the only line of defence. |
| `alejandra` or `nixfmt-rfc-style`, `statix`, `deadnix` | 18 hand-written `.nix` modules with no formatter or linter. `statix` catches antipatterns, `deadnix` finds unused bindings, and a formatter check slots straight into `flake.nix` next to the shellcheck ones. |

## Medium value — clear daily-driver wins

| Tool | Use case here |
| --- | --- |
| `delta` or `difftastic` | Side-by-side, syntax-aware `git diff`/`git show`. Complements `hunkdiff` (review flow) rather than replacing it. |
| `lazygit` | Staging hunks, interactive rebase, and reflog rescue in a TUI. Notably useful given the "stage but don't commit" nix-flake rule in `CLAUDE.md`. |
| `atuin` | Your history is 50k, shared, and fzf-searched. `atuin` adds a real SQLite backend, per-directory filtering, and optional end-to-end-encrypted sync across machines. |
| `eza` | Drop-in `ls` with icons that match the Nerd Font already installed, and `--git` status columns. You already alias `ls`. |
| `yq` | `jq` handles the hook payloads; `yq` handles `docker-compose.yml`, `ci.yml`, and `tmux-nerd-font-window-name.yml` with the same query language. |
| `just` | `setup.sh` and `setup-packages.sh` are growing into a task runner. A `justfile` gives named targets (`just check`, `just switch`, `just docker claude`) without more bash. |
| `watchexec` or `entr` | Re-run `nix flake check` or a hook selftest on file save instead of by hand. |
| `dust` + `duf` (or `ncdu`) | `/nix` growth is a known issue here — `maintenance.nix` even comments that the system profile needs a manual `sudo nix-collect-garbage`. These tell you when it is time. |
| `tealdeer` (`tldr`) | Fast example-first help for the 30+ CLIs above. |

## Situational — add if the workflow appears

| Tool | Use case here |
| --- | --- |
| `ast-grep` | Structural code search/rewrite. Would let `boilerplate-signatures.grep` become a real AST rule instead of a regex list. |
| `act` | Run `ci.yml` locally in Docker before pushing; you already have the Docker opt-in and a sandbox image. |
| `lazydocker` | Only worth it once `enableDocker` is on and containers are long-lived. |
| `hyperfine` | Benchmark hook latency — relevant because every hook runs on the prompt path. |
| `jless` or `fx` | Interactively explore a captured Claude hook JSON payload when debugging one. |
| `glow` | Render the repo's many markdown files (ADRs, skills, repo-map) in the terminal. |
| `tokei` / `scc` | Quick LOC-by-language snapshot for the repo map. |
| `sd` | Simpler find-and-replace than `sed`, and it sidesteps the escaping pain in activation scripts. |
| `git-lfs` | Only if a GGUF model or other large binary ever lands in a repo you own. |
| `cachix` / `comma` | `cachix` if flake builds get slow on a second machine; `comma` (`, <cmd>`) to run a one-off tool without adding it to `home.packages`. |
| `btop` | Nicer than `htop`, with GPU panels — meaningful when `littleCoderGpu` is on. |
