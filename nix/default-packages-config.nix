# Default package configuration - all optional packages disabled
# To customize, run: ./setup-packages.sh

{ config, lib, ... }:

{
  customPackages = {
    enableDocker = false;
    enablePython = false;
    enablePipelineWorker = false;
    enableHerdr = false;
    enableGitHubCopilot = false;
    enableLocalScribe = false;
    enableGitConfig = false;
  };
}
