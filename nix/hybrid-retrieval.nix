{ pkgs, lib, ... }:

let
  # Bump to upgrade. Any git ref works (branch, tag, commit); a change here
  # triggers a reinstall on the next ./setup.sh.
  ref = "main";
  source = "git+https://github.com/MohanTn/hybrid-retrieval-pipeline@${ref}";
in
{
  # hybrid-retrieval (github.com/MohanTn/hybrid-retrieval-pipeline): resident
  # daemon that indexes each repo and ranks files for context-augment.py.
  # Installed as a uv tool (sparse only, no torch) so nothing depends on a
  # local checkout. claude/hooks/session-start/retrieval-warm.sh then indexes
  # every repo on session start for all three harnesses.
  #
  # Not a nix derivation: tree-sitter-language-pack and sqlite-vec ship as
  # prebuilt wheels that uv resolves in seconds, while packaging them in nix
  # means building every grammar from source.
  home.activation.installHybridRetrieval = lib.hm.dag.entryAfter [ "installPackages" ] ''
    stamp="$HOME/.local/share/hybrid-retrieval/installed-source"
    if [ ! -x "$HOME/.local/bin/hybrid-retrieval" ] \
       || [ "$(cat "$stamp" 2>/dev/null)" != "${source}" ]; then
      echo "Installing hybrid-retrieval from ${source}..."
      export PATH="${pkgs.git}/bin:$PATH"
      if run ${pkgs.uv}/bin/uv tool install --force --python 3.12 "hybrid-retrieval @ ${source}"; then
        # Restart a daemon still running the previous version's code.
        run "$HOME/.local/bin/hybrid-retrieval" stop >/dev/null 2>&1 || true
        run mkdir -p "$(dirname "$stamp")"
        if [[ ! -v DRY_RUN ]]; then
          printf '%s' "${source}" > "$stamp"
        fi
      else
        echo "WARNING: hybrid-retrieval install failed, sessions will say so until it succeeds" >&2
      fi
    fi
  '';
}
