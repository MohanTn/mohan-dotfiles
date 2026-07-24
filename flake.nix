{
  description = "Mohan's reproducible machine setup: Claude Code, zsh, git, Neovim (Home Manager flake)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
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
        # Claude scripts plus native edit-no-op + goal-capture/check gates.
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
