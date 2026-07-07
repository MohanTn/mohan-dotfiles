{
  description = "Mohan's reproducible machine setup: Claude Code, Copilot CLI hooks, zsh, git, Neovim, pi (Home Manager flake)";

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
        # Building the activation package validates every module, file link,
        # and package reference without touching the running system.
        home = self.homeConfigurations.${username}.activationPackage;

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

        # Same regression suite for the Copilot CLI port of the hooks, run in
        # a sandbox HOME exactly the way Copilot invokes them (camelCase JSON
        # payload on stdin, JSON decisions on stdout).
        copilot-hooks-selftest = pkgs.runCommand "copilot-hooks-selftest"
          { nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.git ]; }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME/.copilot"
            cp -r ${./copilot/hooks} "$HOME/.copilot/hooks"
            chmod -R u+w "$HOME/.copilot/hooks"
            bash "$HOME/.copilot/hooks/test-hook.sh" selftest > "$out"
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

            echo "all setup.sh checks passed" > "$out"
            cat "$out"
          '';
      };
    };
}
