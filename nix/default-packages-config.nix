# Default package configuration - all optional packages disabled
# To customize, run: ./setup-packages.sh

{ config, lib, ... }:

{
  customPackages = {
    enableDocker = false;
    enablePython = false;
    enablePipelineWorker = false;
    enableGitHubCopilot = false;
    enableLocalScribe = false;
    enableGitConfig = false;
    enableGcloud = false;
    enableLittleCoder = false;
    littleCoderGpu = false;
    enableHomebrew = false;
    brewPackages = [ ];
    # Opt-out, not opt-in: this is the terminal setup the repo is built
    # around, so the packaged default keeps it on.
    enableZsh = true;
    enableTmux = true;
  };
}
