# Nix Debugging
If `nix flake check` or `./setup.sh` fails right after adding/renaming a file in this repo, run `git status --short` first: nix flakes only see git-tracked files, so an untracked file is invisible to sandboxed builds. `git add` (stage, don't commit) fixes it. Don't reach for `nix log`, `--rebuild`, or `--keep-failed` until this is ruled out.
