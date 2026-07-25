# Homebrew on PATH, when it is installed (opt in via ./setup-packages.sh ->
# enableHomebrew; see nix/homebrew.nix). A no-op on machines without brew, so
# this file is unconditionally sourced by nix/zsh.nix.
#
# Kept bash-compatible so the homebrew-shellenv flake check can lint and drive
# it (a comment line must never start with the word shellcheck: it is parsed as
# a directive).

_brew_shellenv() {
  local candidate before
  for candidate in \
    /home/linuxbrew/.linuxbrew/bin/brew \
    "$HOME/.linuxbrew/bin/brew" \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew; do
    [ -x "$candidate" ] || continue

    before="$PATH"
    eval "$("$candidate" shellenv)"
    # `brew shellenv` prepends brew's bin/sbin, which would shadow the Nix
    # toolchain (git, curl, python, ...) with whatever brew happens to have
    # pulled in as a dependency. Nix owns the base toolchain here, so brew
    # goes last: its formulae stay reachable without overriding anything.
    # shellcheck disable=SC2154  # HOMEBREW_PREFIX comes from the eval above
    PATH="$before:$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin"
    export PATH
    return 0
  done
  return 1
}

_brew_shellenv || true
