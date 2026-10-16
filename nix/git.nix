{ ... }:

{
  # Git enable only - userName and userEmail are optional (see optional-packages.nix)
  programs.git = {
    enable = true;
    # hybrid-retrieval keeps its per-repo index in .retrieval/ and the
    # session-start hook creates it in every repo (nix/hybrid-retrieval.nix),
    # so it is ignored globally rather than repo by repo.
    ignores = [ ".retrieval/" ];
  };
}
