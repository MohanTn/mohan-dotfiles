#!/usr/bin/env bash

set -euo pipefail

# Interactive setup for optional packages
# Usage: ./setup-packages.sh

CONFIG_DIR="${HOME}/.config/mohan-dotfiles"
CONFIG_FILE="${CONFIG_DIR}/packages-config.nix"

mkdir -p "$CONFIG_DIR"

echo "======================================"
echo "  Claude Code Helpers: Package Setup"
echo "======================================"
echo ""
echo "Select which optional packages you want to install:"
echo ""

# Functions to ask for yes/no
ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"

  local yesno
  if [ "$default" = "y" ]; then
    read -p "$prompt (Y/n): " yesno
    yesno="${yesno:-y}"
  else
    read -p "$prompt (y/N): " yesno
    yesno="${yesno:-n}"
  fi

  if [[ "$yesno" =~ ^[Yy]$ ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Ask for each optional package
DOCKER=$(ask_yes_no "1. Install Docker and Docker Compose?" "n")
PYTHON=$(ask_yes_no "2. Install Python dev tools (python3, poetry, pip-tools)?" "n")
PIPELINE_WORKER=$(ask_yes_no "3. Install pipeline-worker (npm)?" "n")
HERDR=$(ask_yes_no "4. Install herdr?" "n")
COPILOT=$(ask_yes_no "5. Install GitHub Copilot CLI?" "n")
LOCAL_SCRIBE=$(ask_yes_no "6. Install LocalScribe (from GitHub releases)?" "n")
GIT_CONFIG=$(ask_yes_no "7. Configure Git (set userName and userEmail)?" "n")

echo ""
echo "Generating configuration file..."

# Generate Nix config file
cat > "$CONFIG_FILE" << EOF
# Auto-generated package configuration - do not edit manually
# Run ./setup-packages.sh to regenerate

{ config, lib, ... }:

{
  customPackages = {
    enableDocker = ${DOCKER};
    enablePython = ${PYTHON};
    enablePipelineWorker = ${PIPELINE_WORKER};
    enableHerdr = ${HERDR};
    enableGitHubCopilot = ${COPILOT};
    enableLocalScribe = ${LOCAL_SCRIBE};
    enableGitConfig = ${GIT_CONFIG};
  };
}
EOF

echo "✓ Configuration saved to: $CONFIG_FILE"
echo ""
echo "Selected packages:"
[ "$DOCKER" = "true" ] && echo "  ✓ Docker and Docker Compose"
[ "$PYTHON" = "true" ] && echo "  ✓ Python dev tools"
[ "$PIPELINE_WORKER" = "true" ] && echo "  ✓ pipeline-worker"
[ "$HERDR" = "true" ] && echo "  ✓ herdr"
[ "$COPILOT" = "true" ] && echo "  ✓ GitHub Copilot CLI"
[ "$LOCAL_SCRIBE" = "true" ] && echo "  ✓ LocalScribe (from GitHub)"
[ "$GIT_CONFIG" = "true" ] && echo "  ✓ Git configuration (MohanTn / mohan.tn100@gmail.com)"
echo ""
echo "Next, run:"
echo "  nix flake check --impure && ./setup.sh"
echo ""
