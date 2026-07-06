{ ... }:

{
  # Git enable only - userName and userEmail are optional (see optional-packages.nix)
  programs.git = {
    enable = true;
  };
}
