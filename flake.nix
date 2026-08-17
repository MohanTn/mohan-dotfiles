{
  description = "Mohan's reproducible machine setup: Claude Code, zsh, git, Neovim (Home Manager flake)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    # Only source of packages that must be newer than the 25.05 freeze; see
    # the llama-cpp overlay below. Deliberately not `follows`-ed anywhere.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager }:
    let
      system = "x86_64-linux";

      # llama.cpp, and nothing else, tracks unstable. nixos-25.05 pins build
      # b5311 (May 2025), which knows neither the `gemma4` architecture
      # nix/little-coder.nix's model uses nor its `gemma3n` predecessor: with
      # it, the model loads far enough to print its metadata and then dies
      # with "unknown model architecture". Unstable's b10063 has both (see
      # LLM_ARCH_GEMMA4 in src/llama-arch.cpp). Model formats move faster than
      # a NixOS release, so pinning the runtime to the release channel while
      # the model comes from Hugging Face's latest cannot work. Everything
      # else stays on 25.05 — this is one package, not a channel bump.
      unstable = nixpkgs-unstable.legacyPackages.${system};
      llamaCppOverlay = _final: _prev: {
        inherit (unstable) llama-cpp;
        # GPU build, referenced only when customPackages.littleCoderGpu is on
        # (nix/little-coder.nix). Vulkan rather than CUDA on purpose: the CUDA
        # path pulls the unfree toolkit — libcublas alone unpacks over 3GB,
        # the closure runs to tens of GB, and cache.nixos.org carries none of
        # it (that combination is what filled /nix here). Vulkan reaches the
        # same NVIDIA GPU through the host driver's ICD for a few hundred MB,
        # at roughly 10-20% less throughput. Either way an override means no
        # cache hit for llama.cpp itself, so expect it to compile locally.
        llama-cpp-vulkan = unstable.llama-cpp.override { vulkanSupport = true; };
      };
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ llamaCppOverlay ];
      };
      # Read at eval time so this flake works unmodified on any machine or
      # account name; every nix invocation of it therefore needs --impure
      # (bootstrap.sh, README, and the CI workflow all pass it).
      username = builtins.getEnv "USER";
    in
    {
      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit username; };
        modules = [ ./nix/home.nix ];
      };

      checks.${system} = {
        # Evaluating (not building) the activation package validates every
        # module, option, and home.file source reference without downloading
        # or building the full package closure: zed-editor and dotnet-sdk
        # alone pull in tens of GB of GUI/multimedia libraries that a CI
        # runner has no use for. Referencing .drvPath forces Nix to
        # instantiate every derivation in the tree (still catching bad
        # attribute names, assertion failures, and missing home.file
        # sources); unsafeDiscardOutputDependency strips the string context
        # that would otherwise turn this into a real build dependency on
        # every one of those derivations' outputs.
        home = pkgs.runCommand "home-eval-check" { } ''
          echo "${builtins.unsafeDiscardOutputDependency self.homeConfigurations.${username}.activationPackage.drvPath}" > "$out"
        '';

        # The hooks' own regression suite, run in a sandbox HOME exactly the
        # way Claude Code invokes them (JSON payload on stdin).
        # universal-ctags backs repo-map.sh's symbol pass and python3 backs
        # session-end-audit.sh; without them those checks would pass vacuously.
        hooks-selftest = pkgs.runCommand "hooks-selftest"
          { nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.git pkgs.universal-ctags pkgs.python3 ]; }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME/.claude"
            cp -r ${./claude/hooks} "$HOME/.claude/hooks"
            chmod -R u+w "$HOME/.claude/hooks"
            bash "$HOME/.claude/hooks/test-hook.sh" selftest > "$out"
            cat "$out"
          '';

        # The container images are assembled by an explicit COPY list, while the
        # hooks that must exist are declared in mohan-hooks.json/settings.json —
        # two lists nothing kept in agreement, so the copilot stage silently
        # shipped without user-prompt-submit-context.sh and session-end-audit.sh
        # (Copilot then fails that hook on every fire, invisibly). This ties the
        # manifests to the Dockerfile so the next divergence fails the build.
        docker-hook-parity = pkgs.runCommand "docker-hook-parity"
          { nativeBuildInputs = [ pkgs.bash pkgs.jq ]; }
          ''
            set -euo pipefail
            dockerfile=${./docker/Dockerfile}
            entrypoint=${./docker/entrypoint.sh}
            fail=0

            # Every script mohan-hooks.json registers must be COPY'd in.
            for s in $(jq -r '.hooks[][].bash
                              | capture("\\.copilot/hooks/(?<n>[A-Za-z0-9._-]+)").n' \
                         ${./copilot/hooks/mohan-hooks.json} | sort -u); do
              if ! grep -q "copilot/hooks/$s" "$dockerfile"; then
                echo "MISSING from Dockerfile: copilot/hooks/$s (registered in mohan-hooks.json)" >&2
                fail=1
              else
                echo "ok: copilot/hooks/$s"
              fi
            done

            # Every hook settings.json points at must exist in claude/hooks/,
            # which the Dockerfile copies wholesale.
            for s in $(jq -r '[.hooks[][].hooks[].command, .statusLine.command]
                              | .[] | capture("\\.claude/(hooks/)?(?<n>[A-Za-z0-9._-]+)").n' \
                         ${./claude/settings.json} | sort -u); do
              if [ ! -e "${./claude/hooks}/$s" ] && [ ! -e "${./claude}/$s" ]; then
                echo "MISSING: claude/$s referenced by settings.json" >&2
                fail=1
              else
                echo "ok: claude/$s"
              fi
            done

            # boilerplate-guard.sh sends the model to this path on all three
            # tools, so the container has to actually have it.
            if ! grep -q 'agents/boilerplats' "$entrypoint"; then
              echo "MISSING: entrypoint.sh does not sync agents/boilerplats" >&2
              fail=1
            else
              echo "ok: entrypoint.sh syncs agents/boilerplats"
            fi

            [ "$fail" -eq 0 ] || exit 1
            echo "docker hook parity ok" > "$out"
          '';

        # context-augment.py's own unit/regression suite. It is the largest
        # hook (>400 lines) and the one the Bash selftests can't meaningfully
        # cover, so it gets its own check rather than riding along on
        # test-hook.sh. Needs git: the end-to-end cases build a throwaway repo.
        context-augment-tests = pkgs.runCommand "context-augment-tests"
          { nativeBuildInputs = [ pkgs.python3 pkgs.git ]; }
          ''
            cp -r ${./claude/hooks} hooks
            chmod -R u+w hooks
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            python3 hooks/test_context_augment.py > "$out" 2>&1 || { cat "$out"; exit 1; }
            cat "$out"
          '';

        # feature-plan skill's injector suite. Pure node: built-ins, no npm
        # deps, so it runs hermetically here. (agents/boilerplats' suite needs
        # handlebars from the registry and runs in the CI node-tests job.)
        feature-plan-tests = pkgs.runCommand "feature-plan-tests"
          { nativeBuildInputs = [ pkgs.nodejs_22 ]; }
          ''
            cp -r ${./agents/skills/feature-plan} feature-plan
            chmod -R u+w feature-plan
            cd feature-plan
            node --test > "$out" 2>&1 || { cat "$out"; exit 1; }
            cat "$out"
          '';

        # Same suite for the Copilot CLI hooks, which reuse the Claude scripts
        # through payload translation — so both hook trees are deployed.
        # python3 is here because the context-augmentation case shells out to
        # claude/hooks/context-augment.py.
        copilot-hooks-selftest = pkgs.runCommand "copilot-hooks-selftest"
          { nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.git pkgs.python3 ]; }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME/.claude" "$HOME/.copilot"
            cp -r ${./claude/hooks} "$HOME/.claude/hooks"
            cp -r ${./copilot/hooks} "$HOME/.copilot/hooks"
            chmod -R u+w "$HOME/.claude/hooks" "$HOME/.copilot/hooks"
            bash "$HOME/.copilot/hooks/test-hook.sh" selftest > "$out"
            cat "$out"
          '';

        # Pi hooks extension: TypeScript port that shells out to the same
        # Claude scripts plus a native edit-no-op gate.
        # This used to derive the source path from `builtins.getEnv "PWD"` so
        # that untracked TS files were visible during local --impure work. That
        # made the check silently depend on being invoked from the repo root,
        # and the underlying problem — flakes only seeing git-tracked files —
        # is solved by staging the file (`git add`, no commit needed), which is
        # what CLAUDE.md already prescribes for this repo.
        pi-hooks-selftest = pkgs.runCommand "pi-hooks-selftest"
          # bash/jq/git back the shelled-out gates the handler tests now drive
          # (pre-tool-use-edit-guard.sh, pre-compact.sh and its git diffstat).
          { nativeBuildInputs = [ pkgs.nodejs_22 pkgs.esbuild pkgs.bash pkgs.jq pkgs.git ];
            piHooksDir = ./pi/agent/extensions/hooks;
          }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME/.claude"
            cp -r ${./claude/hooks} "$HOME/.claude/hooks"
            chmod -R u+w "$HOME/.claude/hooks"
            esbuild --bundle --platform=node --format=esm "$piHooksDir/test.ts" \
              --external:@earendil-works/pi-coding-agent \
              --outfile=test.mjs
            node ./test.mjs > "$out"
            cat "$out"
          '';

        # zsh/little-coder.zsh's gcm/mri helpers, linted and driven against a
        # stub little-coder binary in a throwaway repo (LITTLE_CODER_NO_SERVER=1
        # skips llama-server management): exit-code contract, prompt content,
        # and diff truncation. The file is kept bash-compatible on purpose so
        # shellcheck (no zsh dialect support) and bash can exercise it.
        little-coder-helpers = pkgs.runCommand "little-coder-helpers"
          { nativeBuildInputs = [ pkgs.bash pkgs.zsh pkgs.shellcheck pkgs.git ]; }
          ''
            set -euo pipefail
            helpers=${./zsh/little-coder.zsh}

            echo "-- lint: zsh -n + shellcheck (bash dialect)"
            zsh -n "$helpers"
            shellcheck --shell=bash "$helpers"

            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            stub="$TMPDIR/bin"
            mkdir -p "$stub"
            cat > "$stub/little-coder" <<'STUB'
            #!${pkgs.runtimeShell}
            printf '%s\n' "$@" > "''${LC_STUB_ARGS:?}"
            echo stub-message
            STUB
            chmod +x "$stub/little-coder"
            export PATH="$stub:$PATH"
            export LITTLE_CODER_NO_SERVER=1
            export LC_STUB_ARGS="$TMPDIR/stub-args"

            git init -q -b main "$TMPDIR/repo"
            cd "$TMPDIR/repo"
            git config user.email t@t && git config user.name t
            echo one > f.txt && git add f.txt && git commit -qm init

            echo "-- gcm: nothing staged -> exit 1 + stderr message"
            if msg=$(bash -c "source $helpers; gcm" 2>&1); then
              echo "expected gcm to fail with nothing staged" >&2; exit 1
            fi
            echo "$msg" | grep -q 'nothing staged'

            echo "-- gcm: staged change reaches the stub, oversized diff truncated"
            head -c 20000 /dev/zero | tr '\0' 'x' > big.txt
            git add big.txt
            bash -c "source $helpers; gcm" | grep -q stub-message
            grep -q 'conventional commit message' "$LC_STUB_ARGS"
            grep -q '\[diff truncated\]' "$LC_STUB_ARGS"

            echo "-- mri: branch diff vs main reaches the stub"
            git checkout -qb feature && git commit -qm big
            bash -c "source $helpers; mri" | grep -q stub-message
            grep -q 'merge request' "$LC_STUB_ARGS"

            echo "-- mri: on main with no diff -> exit 1"
            git checkout -q main
            if bash -c "source $helpers; mri" 2>/dev/null; then
              echo "expected mri to fail on main" >&2; exit 1
            fi

            # GPU offload: nix/little-coder.nix exports LITTLE_CODER_NGL only
            # when littleCoderGpu is on, so the flag must appear exactly then
            # — a CPU build that silently got -ngl (or a GPU build that did
            # not) is the failure this pins down. Stubs stand in for the
            # server (records its argv, then reports healthy) and for curl
            # (the health probe reads that same marker).
            echo "-- llama-server: -ngl passed only when LITTLE_CODER_NGL is set"
            srv="$TMPDIR/srvbin"
            mkdir -p "$srv"
            cat > "$srv/llama-server" <<'STUB'
            #!${pkgs.runtimeShell}
            printf '%s ' "$@" > "$LC_SERVER_ARGS"
            touch "$LC_SERVER_UP"
            sleep 2
            STUB
            cat > "$srv/curl" <<'STUB'
            #!${pkgs.runtimeShell}
            [ -e "$LC_SERVER_UP" ]
            STUB
            chmod +x "$srv/llama-server" "$srv/curl"
            export PATH="$srv:$PATH"
            export LC_SERVER_ARGS="$TMPDIR/server-args" LC_SERVER_UP="$TMPDIR/server-up"
            export LITTLE_CODER_NO_SERVER=0
            export LITTLE_CODER_GGUF="$TMPDIR/model.gguf"
            touch "$LITTLE_CODER_GGUF"

            rm -f "$LC_SERVER_UP"
            LITTLE_CODER_NGL=42 bash -c "source $helpers; _lc_ensure_server"
            grep -q -- '-ngl 42' "$LC_SERVER_ARGS"

            rm -f "$LC_SERVER_UP" "$LC_SERVER_ARGS"
            bash -c "source $helpers; _lc_ensure_server"
            if grep -q -- '-ngl' "$LC_SERVER_ARGS"; then
              echo "CPU build must not be given -ngl: $(cat "$LC_SERVER_ARGS")" >&2
              exit 1
            fi

            echo "all little-coder helper checks passed" > "$out"
            cat "$out"
          '';

        # The prompt's path segment must shrink with the terminal. Renders
        # the real theme at several $COLUMNS values against a deep fake path
        # and checks the parent folders collapse to single letters as the
        # window narrows. Also pins the settings key: this oh-my-posh reads
        # `properties`, and a segment using `options` is silently ignored,
        # which is exactly how the width template would fail unnoticed.
        prompt-width = pkgs.runCommand "prompt-width"
          { nativeBuildInputs = [ pkgs.bash pkgs.oh-my-posh pkgs.jq ];
            theme = ./zsh/oh-my-posh-catppuccin-mocha.omp.json;
          }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            deep="$HOME/REPO/mohan-dotfiles/agents/skills/feature-plan/references"

            render() {
              COLUMNS="$1" oh-my-posh print primary --config "$theme" \
                --pwd "$deep" --shell zsh --terminal-width "$1" \
                | sed 's/\x1b\[[0-9;]*m//g; s/%{//g; s/%}//g'
            }

            echo "-- path segment reads 'properties', not 'options'"
            jq -e '.blocks[0].segments[] | select(.type == "path") | .properties.max_width' "$theme" >/dev/null

            echo "-- wide terminal keeps the full path"
            render 200 | grep -qF 'mohan-dotfiles/agents/skills/feature-plan/references'

            echo "-- narrow terminal collapses the parents"
            render 70 | grep -qF '~/R/m/a/s/f/references'

            echo "-- intermediate width shortens only as much as it must"
            render 90 | grep -qF '~/R/m/agents/skills/feature-plan/references'

            echo "-- unset COLUMNS falls back to the unshortened path"
            oh-my-posh print primary --config "$theme" --pwd "$deep" --shell zsh \
              | sed 's/\x1b\[[0-9;]*m//g' \
              | grep -qF 'mohan-dotfiles/agents/skills/feature-plan/references'

            echo "all prompt width checks passed" > "$out"
            cat "$out"
          '';

        # zsh/llama-server-gpu.sh: the wrapper that lets a Nix-built Vulkan
        # llama.cpp reach the host NVIDIA driver. Driven against a fake /usr
        # tree and a stub server binary — so this check never builds
        # llama-cpp-vulkan — asserting the three things that make or break it:
        # only NVIDIA libraries reach LD_LIBRARY_PATH, the ICD manifest is
        # discovered, and a machine with no driver fails loudly instead of
        # falling back to a silent CPU run.
        llama-server-gpu = pkgs.runCommand "llama-server-gpu"
          { nativeBuildInputs = [ pkgs.bash pkgs.shellcheck ]; }
          ''
            set -euo pipefail
            script=${./zsh/llama-server-gpu.sh}

            echo "-- lint"
            shellcheck --shell=bash "$script"

            export HOME="$TMPDIR/home"
            mkdir -p "$HOME" "$TMPDIR/usrlib" "$TMPDIR/icd" "$TMPDIR/bin"
            touch "$TMPDIR/usrlib/libGLX_nvidia.so.0" \
                  "$TMPDIR/usrlib/libnvidia-glcore.so.550.0" \
                  "$TMPDIR/usrlib/libstdc++.so.6"
            echo '{}' > "$TMPDIR/icd/nvidia_icd.json"

            cat > "$TMPDIR/bin/server-stub" <<'STUB'
            #!${pkgs.runtimeShell}
            echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
            echo "VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
            echo "ARGS=$*"
            STUB
            chmod +x "$TMPDIR/bin/server-stub"

            export LITTLE_CODER_LLAMA_SERVER="$TMPDIR/bin/server-stub"
            export LITTLE_CODER_GPU_LIBS="$TMPDIR/farm"
            export LITTLE_CODER_GPU_LIB_DIRS="$TMPDIR/usrlib"
            export LITTLE_CODER_VK_ICD_DIRS="$TMPDIR/icd"

            echo "-- driver libs farmed, ICD found, args forwarded"
            res=$(bash "$script" -m model.gguf -ngl 99)
            echo "$res"
            grep -q "LD_LIBRARY_PATH=$TMPDIR/farm" <<<"$res"
            grep -q "VK_ICD_FILENAMES=$TMPDIR/icd/nvidia_icd.json" <<<"$res"
            grep -q 'ARGS=-m model.gguf -ngl 99' <<<"$res"

            echo "-- only NVIDIA libraries are exposed, not the whole host dir"
            [ -e "$TMPDIR/farm/libGLX_nvidia.so.0" ]
            [ -e "$TMPDIR/farm/libnvidia-glcore.so.550.0" ]
            if [ -e "$TMPDIR/farm/libstdc++.so.6" ]; then
              echo "host libstdc++ must not be linked into the farm" >&2; exit 1
            fi

            echo "-- an existing VK_ICD_FILENAMES is respected"
            # Captured, not piped into grep -q: grep exits at the first match
            # and the stub then dies of SIGPIPE mid-output, which pipefail
            # reports as a failed check.
            preset=$(VK_ICD_FILENAMES=/preset.json bash "$script")
            grep -q 'VK_ICD_FILENAMES=/preset.json' <<<"$preset"

            echo "-- no driver libraries -> exit 1, not a silent CPU run"
            rm -rf "$TMPDIR/farm"
            if LITTLE_CODER_GPU_LIB_DIRS="$TMPDIR/empty" bash "$script" 2>"$TMPDIR/err"; then
              echo "expected failure without driver libraries" >&2; exit 1
            fi
            grep -q 'no NVIDIA driver libraries' "$TMPDIR/err"

            echo "-- no ICD manifest -> exit 1 with an actionable message"
            rm -rf "$TMPDIR/farm"
            if LITTLE_CODER_VK_ICD_DIRS="$TMPDIR/empty" bash "$script" 2>"$TMPDIR/err2"; then
              echo "expected failure without an ICD manifest" >&2; exit 1
            fi
            grep -q 'no NVIDIA Vulkan ICD manifest' "$TMPDIR/err2"

            echo "all llama-server GPU wrapper checks passed" > "$out"
            cat "$out"
          '';

        # zsh/homebrew.zsh: brew must end up on PATH when it is installed, and
        # *behind* the Nix toolchain (brew shellenv prepends by default, which
        # would let a brew dependency shadow the managed git/curl/python).
        # Also asserts the file is a no-op when no brew exists, since
        # nix/zsh.nix sources it unconditionally. Bash-compatible on purpose so
        # shellcheck and bash can exercise it.
        homebrew-shellenv = pkgs.runCommand "homebrew-shellenv"
          { nativeBuildInputs = [ pkgs.bash pkgs.zsh pkgs.shellcheck ]; }
          ''
            set -euo pipefail
            helpers=${./zsh/homebrew.zsh}

            echo "-- lint: zsh -n + shellcheck (bash dialect)"
            zsh -n "$helpers"
            shellcheck --shell=bash "$helpers"

            export HOME="$TMPDIR/home"
            mkdir -p "$HOME/.linuxbrew/bin"
            cat > "$HOME/.linuxbrew/bin/brew" <<STUB
            #!${pkgs.runtimeShell}
            echo "export HOMEBREW_PREFIX=$HOME/.linuxbrew"
            echo "export HOMEBREW_CELLAR=$HOME/.linuxbrew/Cellar"
            echo "export PATH=$HOME/.linuxbrew/bin:\$PATH"
            STUB
            chmod +x "$HOME/.linuxbrew/bin/brew"

            cat > assert.sh <<'CHECK'
            source "$1"
            [ "$HOMEBREW_PREFIX" = "$HOME/.linuxbrew" ] || {
              echo "HOMEBREW_PREFIX not exported: '$HOMEBREW_PREFIX'" >&2; exit 1; }
            case "$PATH" in
              /nix-toolchain/bin:*) ;;
              *) echo "Nix paths must stay first, got: $PATH" >&2; exit 1 ;;
            esac
            case "$PATH" in
              *"$HOME/.linuxbrew/bin:$HOME/.linuxbrew/sbin") ;;
              *) echo "brew paths must come last, got: $PATH" >&2; exit 1 ;;
            esac
            CHECK

            echo "-- installed brew: exported, and appended after the Nix paths"
            env -i HOME="$HOME" PATH=/nix-toolchain/bin \
              ${pkgs.bash}/bin/bash assert.sh "$helpers"

            echo "-- no brew installed: sourcing is a silent no-op"
            noop=$(env -i HOME="$TMPDIR/empty" PATH=/nix-toolchain/bin \
              ${pkgs.bash}/bin/bash -c 'source "$1"; echo "$PATH"' _ "$helpers" 2>&1)
            [ "$noop" = "/nix-toolchain/bin" ] || {
              echo "expected an unchanged PATH, got: $noop" >&2; exit 1; }

            echo "all homebrew shellenv checks passed" > "$out"
            cat "$out"
          '';

        # setup.sh: lint it, then exercise the doctor drift audit against a
        # synthetic Home Manager profile (clean, hand-edited, deleted).
        setup-script = pkgs.runCommand "setup-script"
          { nativeBuildInputs = [ pkgs.bash pkgs.shellcheck ]; }
          ''
            script=${./setup.sh}
            bash -n "$script"
            shellcheck "$script"

            export HOME="$TMPDIR/home"
            unset XDG_STATE_HOME
            hf="$HOME/.local/state/nix/profiles/home-manager/home-files"
            mkdir -p "$hf" "$HOME"
            echo managed > "$TMPDIR/zshrc-src"
            ln -s "$TMPDIR/zshrc-src" "$hf/.zshrc"
            ln -s "$hf/.zshrc" "$HOME/.zshrc"

            echo "-- doctor: no generation fails"
            if HOME="$TMPDIR/empty-home" bash "$script" doctor; then
              echo "expected doctor to fail without a generation" >&2; exit 1
            fi

            echo "-- doctor: clean home passes"
            bash "$script" doctor

            echo "-- doctor: hand-edited file fails"
            rm "$HOME/.zshrc"
            echo hacked > "$HOME/.zshrc"
            if bash "$script" doctor; then
              echo "expected doctor to fail on drifted file" >&2; exit 1
            fi

            echo "-- doctor: deleted managed file fails"
            rm "$HOME/.zshrc"
            if bash "$script" doctor; then
              echo "expected doctor to fail on missing file" >&2; exit 1
            fi

            echo "-- migrate_pre_nix_dotfiles: folds a hand-written zshrc into .zshrc.local"
            # shellcheck disable=SC1090
            source "$script"

            echo "-- nix-command/flakes are forced on for every nix call it makes"
            case "''${NIX_CONFIG:-}" in
              *"extra-experimental-features = nix-command flakes"*) ;;
              *) echo "setup.sh must export the flake feature flags" >&2; exit 1 ;;
            esac

            echo "-- an existing NIX_CONFIG is kept, not clobbered"
            NIX_CONFIG="access-tokens = github.com=secret" \
              bash -c 'source "$1"; printf "%s" "$NIX_CONFIG"' _ "$script" \
              | grep -q 'access-tokens = github.com=secret'

            rm -f "$HOME/.zshrc.local"
            echo 'export TOKEN=hand-written-secret' > "$HOME/.zshrc"
            migrate_pre_nix_dotfiles
            grep -qF 'hand-written-secret' "$HOME/.zshrc.local"
            [ -f "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ]

            echo "-- migrate_pre_nix_dotfiles: re-running does not duplicate the block"
            migrate_pre_nix_dotfiles
            count=$(grep -cF 'hand-written-secret' "$HOME/.zshrc.local")
            [ "$count" -eq 1 ]

            echo "-- migrate_pre_nix_dotfiles: a symlinked (already-managed) zshrc is left alone"
            rm -f "$HOME/.zshrc.local"
            rm "$HOME/.zshrc"
            ln -s "$hf/.zshrc" "$HOME/.zshrc"
            migrate_pre_nix_dotfiles
            [ ! -e "$HOME/.zshrc.local" ]

            echo "-- ensure_google_chrome: skips cleanly without apt-get"
            out_msg="$(ensure_google_chrome)"
            case "$out_msg" in
              *"skipping Google Chrome"*) ;;
              *) echo "expected apt-less skip message, got: $out_msg" >&2; exit 1 ;;
            esac

            echo "all setup.sh checks passed" > "$out"
            cat "$out"
          '';
      };
    };
}
