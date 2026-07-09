{ pkgs, lib, ... }:

let
  # pi loads the extensions' TypeScript directly; node_modules is only for
  # local typecheck/test runs and must never end up in the store.
  extensionsSrc = builtins.path {
    path = ../pi/agent/extensions;
    name = "pi-extensions";
    filter = path: type: baseNameOf path != "node_modules";
  };

  # Self-updating npm CLIs, installed natively (not pinned by Nix) so they
  # stay current. Bootstrapped only when missing.
  npmGlobals = [
    "pipeline-worker"
    "@google/gemini-cli"
    "freebuff"
    "mcp-sonar-analysis"
    "@github/copilot"
  ];
in
{
  # The extensions need a writable directory (npm install for dev typecheck
  # drops node_modules next to the sources), so they are copied rather than
  # store-linked. cp -rT overwrites tracked files but leaves an existing
  # node_modules untouched.
  home.activation.piExtensions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "$HOME/.pi/agent/extensions"
    # legacy install.sh symlinks must go first, or cp would write through
    # them into the repo checkout
    for entry in "$HOME/.pi/agent/extensions"/*; do
      if [ -L "$entry" ]; then
        run rm "$entry"
      fi
    done
    run cp -rT --no-preserve=mode,ownership ${extensionsSrc} "$HOME/.pi/agent/extensions"
  '';

  home.activation.piCodingAgent = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    if [ ! -d "$NPM_CONFIG_PREFIX/lib/node_modules/@earendil-works/pi-coding-agent" ] \
      && [ ! -d "/usr/local/lib/node_modules/@earendil-works/pi-coding-agent" ]; then
      run ${pkgs.nodejs_22}/bin/npm install -g --ignore-scripts @earendil-works/pi-coding-agent
    fi
  '';

  home.activation.npmGlobalTools = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    missing=""
    for tool in ${lib.concatStringsSep " " (map lib.escapeShellArg npmGlobals)}; do
      if [ ! -d "$NPM_CONFIG_PREFIX/lib/node_modules/$tool" ] \
        && [ ! -d "/usr/local/lib/node_modules/$tool" ]; then
        missing="$missing $tool"
      fi
    done
    if [ -n "$missing" ]; then
      # shellcheck disable=SC2086
      run ${pkgs.nodejs_22}/bin/npm install -g $missing
    fi
  '';
}
