# mohan-dotfiles

Set up a whole Linux or WSL machine with one command. This repo is a Nix flake that installs and configures the shell, editor, git, and three AI coding agents, pinned so every machine you run it on ends up identical.

**What you get:** zsh (zinit plugins, oh-my-posh prompt, fzf-tab, autosuggestions) · Neovim (kickstart.nvim, LSP for C#/TypeScript) · tmux · git · Claude Code, GitHub Copilot CLI, and Pi, all sharing one set of instructions, skills, and safety hooks · Alacritty · ripgrep, fd, fzf, jq, and the rest of the CLI toolkit.

---

## Set up a new machine

### Before you start

- **Linux or WSL2.** Nothing else is supported.
- **git and curl** installed. Everything else, including Nix itself, is installed for you.
- **A GitHub SSH key**, or swap the clone URL below for HTTPS.
- **~5 GB of disk** and 10–20 minutes for the first run. Later runs take seconds.

You do *not* need Nix, Node, or Python beforehand.

### Three steps

```bash
# 1. Clone to the expected path (this exact location matters — see below)
git clone git@github.com:MohanTn/mohan-dotfiles.git ~/REPO/mohan-dotfiles

# 2. Pick your optional packages (interactive, ~30 seconds)
~/REPO/mohan-dotfiles/setup-packages.sh

# 3. Install and apply everything
~/REPO/mohan-dotfiles/setup.sh
```

Then **open a new terminal** — the login shell changes to zsh, and the current session won't pick that up.

> **The path is not negotiable.** The repo must live at `~/REPO/mohan-dotfiles`. Your username doesn't matter: the flake reads `$USER` when it evaluates, so any account works unmodified.

### What each step actually does

**Step 2 — `setup-packages.sh`** asks eight yes/no questions (Docker, Python dev tools, pipeline-worker, GitHub Copilot CLI, LocalScribe, git identity, little-coder, Homebrew — the Homebrew answer also asks which formulae to install) and saves your answers to `~/.config/mohan-dotfiles/packages-config.nix`. That file lives outside the repo and is never committed, so your choices are yours alone. Skip this step and every optional package stays off (`nix/default-packages-config.nix` applies instead). Re-run it any time to change your mind, then re-run `setup.sh`.

**Step 3 — `setup.sh`** does the real work, in order:

1. Installs Nix via the Determinate Systems installer, if missing.
2. Activates the Home Manager configuration. Existing files that would be overwritten are preserved as `*.hm-backup` — nothing of yours is destroyed.
3. Folds any hand-written `~/.zshrc` into `~/.zshrc.local` so your existing customizations survive.
4. Switches your login shell to zsh.
5. Installs Google Chrome if missing (apt machines only — the `axi` browser bridge looks for Chrome at `/opt/google/chrome`; without it, `axi` falls back to a debug Chromium).
6. Runs a drift audit and prints a summary.

### Did it work?

```bash
./setup.sh doctor   # verifies every managed file still comes from the Nix store
```

Exit code 0 and "all checks passed" means you're done. Open a new terminal and you should see the Catppuccin-themed prompt.

### If something goes wrong

| Symptom | Fix |
| --- | --- |
| `error: ... does not exist` right after you added or renamed a file | Nix only sees git-tracked files. Run `git add` on the new file (staging is enough, no commit needed) and retry. This is the single most common confusion — check it before anything else. |
| Shell still isn't zsh | Open a *new* terminal. If it persists, log out and back in; the login shell change needs a fresh session. |
| `No space left on device` while building | `/nix` is full. `nix-collect-garbage --delete-older-than 7d` (and the same with `sudo`), delete stale `result` symlinks — they are GC roots — then `nix store optimise`. The daily `tools-maintenance` timer does the first part for you once a switch has succeeded. |
| little-coder ignores the GPU | `littleCoderGpu` must be on (prompt 7a), and the wrapper needs an NVIDIA Vulkan ICD in `/usr/share/vulkan/icd.d`. Check `~/.cache/little-coder/llama-server.log` for `-ngl` and a Vulkan device line; `rm -rf ~/.cache/little-coder/gpu-libs` forces the driver-library farm to rebuild after a driver upgrade. |
| `setup.sh doctor` reports drift | Something edited a managed file by hand. Re-run `./setup.sh` to restore it; your edited copy is kept as `*.hm-backup`. |
| Command not found after install | `~/.local/bin` and `~/.npm-global/bin` are added to `PATH` by the managed zshrc — open a new terminal. |
| Nix commands fail with "experimental feature" | Run `./setup.sh` once. It exports the flags for its own run and installs a managed `~/.config/nix/nix.conf` that enables `nix-command` + `flakes` for every shell afterward. Machine-local Nix settings (substituters, access-tokens) go in `~/.config/nix/nix.conf.local`, which that file includes. |

---

## Everyday use

Configs are served **read-only** from the Nix store. So the loop is always: edit in this repo → apply → commit.

```bash
./setup.sh                                  # apply your changes
git add -A && git commit -m "..." && git push
```

Re-running `setup.sh` when nothing changed is a no-op, so it's safe to run any time. It's also the update command — there's no separate one.

```bash
./setup.sh doctor    # audit only, changes nothing, exits 1 on drift
./setup.sh upgrade   # update pinned nixpkgs/home-manager, then apply
```

Because the live files under `$HOME` are store symlinks, editing them directly does nothing lasting — the next `setup.sh` reverts it. Always edit the repo. This applies to Neovim too: `~/.config/nvim` is a read-only store symlink, so nvim config changes need a `./setup.sh` before they take effect.

**One deliberate exception:** `~/.claude/settings.json` is a writable copy, because Claude Code edits it at runtime (permission grants, `/config`). Every switch refreshes it from the repo; if the live file had drifted, the previous version is kept as `settings.json.hm-prev`. To keep a runtime change permanently, copy it back into `claude/settings.json` before switching.

### Where things are configured

| What | Where | Committed? |
| --- | --- | --- |
| Which optional packages are installed | `setup-packages.sh` → `~/.config/mohan-dotfiles/packages-config.nix` | No — machine-local |
| Shell: aliases, plugins, prompt | `nix/zsh.nix` | Yes |
| Prompt theme | `zsh/oh-my-posh-catppuccin-mocha.omp.json` | Yes |
| Neovim | `nvim/init.lua`, `nvim/lua/custom/plugins/` | Yes |
| Non-secret env vars | `home.sessionVariables` in `nix/zsh.nix` | Yes |
| **Secrets** | `~/.zshrc.local` | **No — never commit these** |
| Git identity | Answer yes to prompt 6 in `setup-packages.sh`, or edit `nix/optional-packages.nix` | Config yes, your answer no |
| Homebrew formulae | `brewPackages` in `~/.config/mohan-dotfiles/packages-config.nix` (prompt 8 of `setup-packages.sh`) | No — machine-local |
| Nix's own settings | `nix/nix-conf.nix` (managed) + `~/.config/nix/nix.conf.local` (machine-local) | Config yes, local file no |

### Secrets

Never put a real secret in a `.nix` file — they're world-readable in the Nix store. Put them in `~/.zshrc.local`, which the managed zshrc sources last:

```bash
export PIPELINE_WORKER_GITHUB_TOKEN="github_pat_..."
```

That file isn't managed by Nix, so no `setup.sh` run is needed — just open a new terminal or run `exec zsh`.

---

## What's in here

```
setup.sh              one entry point: install, apply, doctor, upgrade
setup-packages.sh     interactive optional-package picker
flake.nix             pinned inputs + all CI checks
nix/                  one Home Manager module per concern (packages, zsh, git,
                      nvim, tmux, alacritty, and one per agent)
agents/               shared agent layer → ~/.agents
                        AGENTS.md    global instructions, used by all 3 agents
                        skills/      reusable agent skills
                        boilerplats/ scaffold.js code generator + templates
claude/               → ~/.claude (settings, hooks, statusline)
copilot/              → ~/.copilot (hooks, generated instructions)
pi/                   → ~/.pi (hook extension, sandbox extension)
nvim/                 → ~/.config/nvim (kickstart.nvim)
zsh/                  prompt theme + shell helpers sourced by nix/zsh.nix
docker/               containerized workspace for each agent
```

**The agent layer is the interesting part.** `agents/AGENTS.md` is the single authored system prompt: Claude imports it, while Copilot's and Pi's instruction files are generated from it at build time so they can't drift. The safety hooks — blocking no-op edits, breaking retry loops, verifying new imports resolve, mandating the scaffold generator for boilerplate, replaying context across a compaction — are authored once in `claude/hooks/` and reused by all three. Copilot and Pi shell out to those same scripts through thin adapters rather than reimplementing them, so there is exactly one copy of each rule.

### Containers

Run any agent in an isolated container with only `/workspace` mounted:

```bash
cd docker && docker compose run --rm claude    # or: copilot, pi
```

Credentials and session history persist in named volumes across runs.

---

## Not managed by Nix (on purpose)

- **The agent CLIs** (Claude Code, Pi, Copilot CLI and other npm globals) self-update and move fast, so they're bootstrapped by their own installers only when missing — Claude into `~/.local/bin`, npm globals into `~/.npm-global`.
- **The Docker daemon** is a system service: install it per <https://docs.docker.com/engine/install/>.

## Testing

```bash
nix flake check --impure    # everything CI runs
```

Eight checks: the full home configuration evaluates; `setup.sh` is shellchecked and its drift audit exercised against a synthetic profile; the Claude, Copilot, and Pi hook suites run; `context-augment.py` and the feature-plan injector run their unit tests; and a parity check asserts the container images ship every hook the configs actually register. The boilerplate generator's suite needs the npm registry, so it runs as a separate CI job rather than inside the offline Nix sandbox.

Individual hooks can be driven by hand:

```bash
claude/hooks/test-hook.sh list          # every hook, its event, what it does
claude/hooks/test-hook.sh selftest      # regression checks
claude/hooks/test-hook.sh run pre-tool-use-edit-guard.sh   # with a sample payload
```

Hook runtime state (logs, loop counters, digests) lives in `~/.local/state/claude-hooks/`, never in this repo.

## WSL notes

- Zed needs WSLg, standard on Windows 11.
- `wslu` provides `wslview` for opening URLs and files on the Windows side.
