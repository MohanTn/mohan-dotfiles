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
COPILOT=$(ask_yes_no "4. Install GitHub Copilot CLI?" "n")
LOCAL_SCRIBE=$(ask_yes_no "5. Install LocalScribe (from GitHub releases)?" "n")
GIT_CONFIG=$(ask_yes_no "6. Configure Git (set userName and userEmail)?" "n")
LITTLE_CODER=$(ask_yes_no "7. Install little-coder + local Gemma model (~4GB download)?" "n")
LITTLE_CODER_GPU=false
if [ "$LITTLE_CODER" = "true" ]; then
  # CPU inference is the safe default: the Vulkan build compiles llama.cpp
  # locally (an override never hits the binary cache) and needs a host driver
  # with Vulkan support.
  LITTLE_CODER_GPU=$(ask_yes_no "   7a. Run its model on the GPU (Vulkan build)?" "n")
fi
HOMEBREW=$(ask_yes_no "8. Install the Homebrew package manager (brew)?" "n")

# Formulae are installed on every ./setup.sh run (already-installed ones are
# skipped). Nix stays the source of truth for the base toolchain; this is for
# what nixpkgs lacks or what must track upstream releases.
BREW_LIST=""
if [ "$HOMEBREW" = "true" ]; then
  read -p "   Formulae to install with brew (space-separated, blank for none): " BREW_INPUT
  for pkg in ${BREW_INPUT:-}; do
    BREW_LIST="${BREW_LIST} \"${pkg}\""
  done
fi

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
    enableGitHubCopilot = ${COPILOT};
    enableLocalScribe = ${LOCAL_SCRIBE};
    enableGitConfig = ${GIT_CONFIG};
    enableLittleCoder = ${LITTLE_CODER};
    littleCoderGpu = ${LITTLE_CODER_GPU};
    enableHomebrew = ${HOMEBREW};
    brewPackages = [${BREW_LIST} ];
  };
}
EOF

echo "✓ Configuration saved to: $CONFIG_FILE"
echo ""
echo "Selected packages:"
[ "$DOCKER" = "true" ] && echo "  ✓ Docker and Docker Compose"
[ "$PYTHON" = "true" ] && echo "  ✓ Python dev tools"
[ "$PIPELINE_WORKER" = "true" ] && echo "  ✓ pipeline-worker"
[ "$COPILOT" = "true" ] && echo "  ✓ GitHub Copilot CLI"
[ "$LOCAL_SCRIBE" = "true" ] && echo "  ✓ LocalScribe (from GitHub)"
[ "$GIT_CONFIG" = "true" ] && echo "  ✓ Git configuration (MohanTn / mohan.tn100@gmail.com)"
[ "$LITTLE_CODER" = "true" ] && echo "  ✓ little-coder + Gemma GGUF (local, gcm/mri helpers)"
[ "$LITTLE_CODER_GPU" = "true" ] && echo "    ↳ GPU offload (Vulkan llama.cpp)"
[ "$HOMEBREW" = "true" ] && echo "  ✓ Homebrew${BREW_LIST:+ (formulae:${BREW_LIST//\"/})}"
echo ""
echo "Next, run:"
echo "  nix flake check --impure && ./setup.sh"
echo ""
