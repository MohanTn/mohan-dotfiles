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
        hooks-selftest = pkgs.runCommand "hooks-selftest"
          { nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.git ]; }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME/.claude"
            cp -r ${./claude/hooks} "$HOME/.claude/hooks"
            chmod -R u+w "$HOME/.claude/hooks"
            bash "$HOME/.claude/hooks/test-hook.sh" selftest > "$out"
            cat "$out"
          '';

        # Same suite for the Copilot CLI hooks, which reuse the Claude scripts
        # through payload translation — so both hook trees are deployed.
        copilot-hooks-selftest = pkgs.runCommand "copilot-hooks-selftest"
          { nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.git ]; }
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
        # Uses builtins.readFile instead of builtins.path so untracked TS
        # files are accessible during local --impure development (flakes
        # only see git-tracked files for ./path interpolation).
        pi-hooks-selftest = pkgs.runCommand "pi-hooks-selftest"
          { nativeBuildInputs = [ pkgs.nodejs_22 pkgs.esbuild ];
            piHooksDir = builtins.path {
              path =
                let
                  repo = builtins.toPath (builtins.getEnv "PWD");
                in repo + "/pi/agent/extensions/hooks";
              name = "pi-hooks";
            };
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
