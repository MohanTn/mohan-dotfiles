{
  description = "Mohan's reproducible machine setup: Claude Code, zsh, git, tmux, Neovim, pi (Home Manager flake)";

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
    in
    {
      homeConfigurations."mohan" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./nix/home.nix ];
      };

      checks.${system} = {
        # Building the activation package validates every module, file link,
        # and package reference without touching the running system.
        home = self.homeConfigurations."mohan".activationPackage;

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
      };
    };
}
