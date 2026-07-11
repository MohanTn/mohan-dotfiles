# chrome-devtools-axi browser wiring (sourced by nix/zsh.nix).
#
# The bridge discovers Google Chrome only at its native stable-channel
# location, /opt/google/chrome/chrome; setup.sh installs it there on apt
# machines. On machines without it, the `axi` wrapper below starts a headless
# Chromium with remote debugging and points the bridge at that instance via
# CHROME_DEVTOOLS_AXI_BROWSER_URL.

_axi_debug_url="http://127.0.0.1:9222"

_axi_chromium_bin() {
  command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null
}

_axi_debug_up() {
  curl -sf --max-time 1 "$_axi_debug_url/json/version" >/dev/null 2>&1
}

# axi: chrome-devtools-axi with automatic browser fallback.
axi() {
  if [ -x /opt/google/chrome/chrome ]; then
    npx -y chrome-devtools-axi "$@"
    return
  fi
  local bin
  bin="$(_axi_chromium_bin)"
  if [ -z "$bin" ]; then
    echo "axi: neither Google Chrome nor Chromium found; run ~/REPO/mohan-dotfiles/setup.sh" >&2
    return 1
  fi
  if ! _axi_debug_up; then
    # /tmp keeps the throwaway profile out of ~/.local, which the Chromium
    # snap cannot write to (snap confinement blocks hidden top-level dirs).
    "$bin" --headless=new --remote-debugging-port=9222 \
      --user-data-dir="/tmp/chrome-devtools-axi-chromium-$USER" \
      --no-first-run --disable-gpu about:blank >/dev/null 2>&1 &!
    local _i
    for _i in {1..20}; do
      _axi_debug_up && break
      sleep 0.5
    done
    if ! _axi_debug_up; then
      echo "axi: Chromium did not open the debugging port within 10s" >&2
      return 1
    fi
  fi
  CHROME_DEVTOOLS_AXI_BROWSER_URL="$_axi_debug_url" npx -y chrome-devtools-axi "$@"
}

# When Chrome is absent but a debug Chromium is already listening (e.g. one
# started by a previous `axi` call), direct `npx -y chrome-devtools-axi`
# invocations, like the Claude Code skill's, should find it too, so surface
# the URL to the whole shell.
if [ ! -x /opt/google/chrome/chrome ] && [ -z "${CHROME_DEVTOOLS_AXI_BROWSER_URL:-}" ] && _axi_debug_up; then
  export CHROME_DEVTOOLS_AXI_BROWSER_URL="$_axi_debug_url"
fi
