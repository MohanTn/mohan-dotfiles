# Table-formatted output for commands whose default output is already
# columnar but not visually a table: `docker ps` and `ollama ps` get
# reformatted as tab-separated data and piped through `tidy-viewer`, which
# draws a bordered, aligned table. `ls -la` gets its table look from
# the `ls` alias in nix/zsh.nix (eza's --header long format) instead, since
# it's flag-driven rather than subcommand-driven.
#
# Both wrappers only intercept the `ps` subcommand; every other invocation
# passes straight through to the real binary untouched.

if command -v docker >/dev/null 2>&1; then
  docker() {
    if [[ "$1" == "ps" ]]; then
      shift
      command docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' "$@" \
        | tidy-viewer -s $'\t'
    else
      command docker "$@"
    fi
  }
fi

if command -v ollama >/dev/null 2>&1; then
  ollama() {
    if [[ "$1" == "ps" ]]; then
      # ollama ps has no --format flag; its columns are whitespace-padded,
      # so squeeze runs of spaces into a single tab before handing off to
      # tidy-viewer.
      command ollama ps | tr -s ' ' '\t' | tidy-viewer -s $'\t'
    else
      command ollama "$@"
    fi
  }
fi
