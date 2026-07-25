# Body of the `llama-server` wrapper installed by nix/little-coder.nix when
# customPackages.littleCoderGpu is on. Kept as a repo file, not an inline Nix
# string, so the llama-server-gpu flake check can lint and drive it without
# building llama-cpp itself.
#
# Why a wrapper at all: a Nix-built Vulkan llama.cpp has to reach the *host*
# NVIDIA driver, which nixpkgs cannot ship — the ICD manifest lives in
# /usr/share/vulkan/icd.d and the libraries it names in the distro's library
# directory. Putting that whole directory on LD_LIBRARY_PATH is the usual
# advice and the usual way to break a Nix binary (the host's libstdc++ and
# libcurl shadow the ones it was linked against), so this links only the
# NVIDIA libraries into a private directory and exposes that instead.
#
# Environment (defaults match Ubuntu and WSL2; the flake check overrides them
# to drive this against a fake /usr tree):
#   LITTLE_CODER_LLAMA_SERVER  real binary to exec (set by the Nix wrapper)
#   LITTLE_CODER_GPU_LIBS      where the symlink farm is built
#   LITTLE_CODER_GPU_LIB_DIRS  driver library directories to scan
#   LITTLE_CODER_VK_ICD_DIRS   Vulkan ICD manifest directories to scan

server="${LITTLE_CODER_LLAMA_SERVER:?LITTLE_CODER_LLAMA_SERVER is not set}"
farm="${LITTLE_CODER_GPU_LIBS:-${XDG_CACHE_HOME:-$HOME/.cache}/little-coder/gpu-libs}"
lib_dirs="${LITTLE_CODER_GPU_LIB_DIRS:-/usr/lib/x86_64-linux-gnu /usr/lib/wsl/lib /usr/lib64}"
icd_dirs="${LITTLE_CODER_VK_ICD_DIRS:-/usr/share/vulkan/icd.d /etc/vulkan/icd.d}"

# The stamp marks a completed farm; deleting it (or the directory) is how you
# force a rebuild after a driver upgrade.
if [ ! -e "$farm/.stamp" ]; then
  rm -rf "$farm"
  mkdir -p "$farm"
  # shellcheck disable=SC2086  # the *_dirs vars are deliberately word-split
  for dir in $lib_dirs; do
    [ -d "$dir" ] || continue
    for lib in "$dir"/libnvidia-*.so* "$dir"/libGLX_nvidia.so* "$dir"/libcuda.so*; do
      [ -e "$lib" ] && ln -sf "$lib" "$farm/"
    done
  done
  touch "$farm/.stamp"
fi

if [ ! -e "$farm/libGLX_nvidia.so.0" ] && [ ! -e "$farm/libcuda.so.1" ]; then
  echo "llama-server: no NVIDIA driver libraries found in: $lib_dirs" >&2
  echo "install the host driver, or set customPackages.littleCoderGpu = false" >&2
  exit 1
fi

# The Vulkan loader finds drivers through this manifest list. On NixOS it
# comes from /run/opengl-driver; everywhere else it has to be pointed at the
# distro's manifest explicitly. An already-set value wins, so a machine with a
# working Vulkan setup is left alone.
if [ -z "${VK_ICD_FILENAMES:-}" ]; then
  icds=""
  # shellcheck disable=SC2086  # the *_dirs vars are deliberately word-split
  for dir in $icd_dirs; do
    [ -d "$dir" ] || continue
    for json in "$dir"/*nvidia*.json; do
      [ -e "$json" ] && icds="${icds:+$icds:}$json"
    done
  done
  if [ -z "$icds" ]; then
    echo "llama-server: no NVIDIA Vulkan ICD manifest found in: $icd_dirs" >&2
    echo "install the driver's Vulkan support (Debian/Ubuntu: nvidia-driver ships nvidia_icd.json)," >&2
    echo "or set VK_ICD_FILENAMES yourself" >&2
    exit 1
  fi
  export VK_ICD_FILENAMES="$icds"
fi

export LD_LIBRARY_PATH="$farm${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$server" "$@"
