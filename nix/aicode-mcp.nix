{ config, pkgs, lib, ... }:

# aicode-mcp (github.com/MohanTn/aicode-mcp-dotnet): scaffold and architect
# MCP servers shared by Claude Code, Copilot CLI and Pi. Opt-in via
# ./setup-packages.sh (customPackages.enableAicodeMcp). The servers are
# stdio-only, so there is no daemon: each harness spawns `aicode-mcp
# mcp-serve` per session. See aicode-mcp/aicode-mcp.sh for the steps.
let
  cfg = config.customPackages;
  dotnet = pkgs.dotnetCorePackages.sdk_10_0;
  dir = "$HOME/.local/share/aicode-mcp-dotnet";
  script = ../aicode-mcp/aicode-mcp.sh;
  path = lib.makeBinPath [ pkgs.git pkgs.jq pkgs.coreutils pkgs.bash ];

  # Runs the published dll with the nix runtime, so no global dotnet tool or
  # DOTNET_ROOT is needed and a `git pull` + republish takes effect at once.
  wrapper = pkgs.writeShellScriptBin "aicode-mcp" ''
    dll="${dir}/.publish/aicode-mcp.dll"
    if [ ! -f "$dll" ]; then
      echo "aicode-mcp: $dll missing, run ./setup.sh to build it" >&2
      exit 1
    fi
    exec ${dotnet}/bin/dotnet "$dll" "$@"
  '';
in
{
  home.packages = lib.optionals cfg.enableAicodeMcp [ wrapper ];

  # After every installer, so `claude` exists and the copilot/pi config
  # writers above have already run.
  home.activation.aicodeMcp = lib.hm.dag.entryAfter
    [ "installPackages" "installClaude" "installPi" "removeCopilotScaffoldMcp" ]
    (if cfg.enableAicodeMcp then ''
      echo "Setting up aicode-mcp..."
      (PATH="${path}:$PATH" DOTNET=${dotnet}/bin/dotnet run ${pkgs.bash}/bin/bash ${script} install) \
        || echo "Warning: aicode-mcp setup failed, continuing" >&2
    '' else ''
      if [ -e "${dir}/.registered" ]; then
        (PATH="${path}:$PATH" run ${pkgs.bash}/bin/bash ${script} unregister) \
          || echo "Warning: aicode-mcp unregister failed, continuing" >&2
      fi
    '');
}
