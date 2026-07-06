{ config, ... }:

let
  repo = "${config.home.homeDirectory}/REPO/claude-code-helpers";
in
{
  # The single out-of-store exception: LazyVim writes lazy-lock.json into the
  # config dir on :Lazy update, and that lockfile is committed on purpose to
  # pin plugin versions. A read-only store link would break plugin updates,
  # so ~/.config/nvim points at the live repo checkout instead.
  xdg.configFile."nvim".source = config.lib.file.mkOutOfStoreSymlink "${repo}/nvim";
}
