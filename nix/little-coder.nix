{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.customPackages;

  # @earendil-works/pi-coding-agent ships a bundled npm-shrinkwrap.json, which
  # npm honours over the project lockfile for that whole subtree. Three of its
  # entries (pi-agent-core, pi-ai, pi-tui) have a `resolved` URL but no
  # `integrity`, so npm asks for those tarballs with nothing to match against
  # the offline cache and the install dies with ENOTCACHED — under
  # importNpmLock because the shrinkwrap ignores the file:/nix/store rewrites,
  # and under fetchNpmDeps because its cache entries carry no response headers
  # and are only usable when the request supplies an integrity to match.
  # Repacking the tarball without the shrinkwrap hands resolution back to the
  # project lockfile, where every entry does have one (see the vendored
  # ./little-coder/package-lock.json, whose three gaps are filled from the
  # registry's own dist.integrity). That entry's own `integrity` and
  # `hasShrinkwrap` are stripped from the vendored lockfile too: the repacked
  # tarball no longer hashes to the published one, and npm would fail the
  # install with EINTEGRITY. Re-check all of this on version bumps.
  #
  # The vendored package.json also drops upstream's `overrides`
  # (node-domexception -> ./vendor/node-domexception). That override only
  # silences a deprecation warning during `npm install -g little-coder` — the
  # shim just re-exports Node's native DOMException — but it makes npm resolve
  # a tree node the lockfile has no entry for, and the resulting symlink
  # dangles when buildNpmPackage canonicalizes symlinks. Without it the tree
  # matches the lockfile exactly and the real package is used.
  piCodingAgentVersion = "0.79.4";
  piCodingAgentUnshrinkwrapped =
    pkgs.runCommand "pi-coding-agent-${piCodingAgentVersion}-noshrinkwrap.tgz" { } ''
      mkdir unpacked
      tar xzf ${pkgs.fetchurl {
        url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${piCodingAgentVersion}.tgz";
        hash = "sha512-PthzVzM5m4XH/hrU+2fVjuwuH5M4eMFWbd0NCRScH14XKpwlPc8/Fh6JDz0jQb5kTBT9oQT183YLTHVVulFL9A==";
      }} -C unpacked
      rm unpacked/package/npm-shrinkwrap.json
      tar czf $out -C unpacked package
    '';

  # Nix-native build (feature-plan decision: fetchFromGitHub, not the npm
  # installer little-coder itself recommends) — fully pinned, no self-update.
  # To upgrade: bump version + hash and re-vendor
  # nix/little-coder/{package,package-lock}.json from the new tag.
  #
  # importNpmLock instead of npmDepsHash: each dependency becomes its own
  # fixed-output fetch keyed by the integrity hashes already in the lockfile,
  # so there is no opaque cache hash to keep in sync. The lockfile is vendored
  # because importNpmLock reads it at eval time, before src is fetched.
  littleCoder = pkgs.buildNpmPackage {
    pname = "little-coder";
    version = "1.12.0";
    src = pkgs.fetchFromGitHub {
      owner = "itayinbarr";
      repo = "little-coder";
      rev = "v1.12.0"; # = 24dea1ce2a6d026d0ae1962e449015390fab6ed4
      hash = "sha256-pnHPaA2UyTfeaifJMK/KCdPdlTi7Zwhs4l1xjbLwCA8=";
    };
    npmDeps = pkgs.importNpmLock {
      npmRoot = ./little-coder;
      packageSourceOverrides."node_modules/@earendil-works/pi-coding-agent" =
        piCodingAgentUnshrinkwrapped;
    };
    npmConfigHook = pkgs.importNpmLock.npmConfigHook;
    # No build script — the launcher (bin/little-coder.mjs) wires everything
    # at run time; --ignore-scripts stops playwright's postinstall from
    # trying to download browsers inside the sandbox.
    dontNpmBuild = true;
    npmFlags = [ "--ignore-scripts" ];
    nodejs = pkgs.nodejs_22;
  };

  modelDir = "${config.home.homeDirectory}/.cache/models";
  modelPath = "${modelDir}/${cfg.littleCoderModelFile}";

  llamaCpp = if cfg.littleCoderGpu then pkgs.llama-cpp-vulkan else pkgs.llama-cpp;

  # See zsh/llama-server-gpu.sh for what this does and why. The default
  # assignment (rather than a plain export) keeps the script drivable against
  # a stub binary in the flake check. writeShellApplication, not
  # writeShellScriptBin, so the body is shellcheck'd at build time too.
  llamaServerGpuWrapper = pkgs.writeShellApplication {
    name = "llama-server";
    # util-linux for flock, which serializes concurrent wrapper invocations
    # rebuilding the GPU lib symlink farm (see zsh/llama-server-gpu.sh).
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      LITTLE_CODER_LLAMA_SERVER="''${LITTLE_CODER_LLAMA_SERVER:-${llamaCpp}/bin/llama-server}"
      export LITTLE_CODER_LLAMA_SERVER
    '' + builtins.readFile ../zsh/llama-server-gpu.sh;
  };
in
{
  options.customPackages = {
    enableLittleCoder =
      mkEnableOption "little-coder harness + local Gemma GGUF (gcm/mri helpers)";
    littleCoderModelRepo = mkOption {
      type = types.str;
      default = "unsloth/gemma-4-E4B-it-qat-GGUF";
      description = "Hugging Face repo the GGUF model is downloaded from.";
    };
    littleCoderModelFile = mkOption {
      type = types.str;
      # QAT (quantization-aware trained) UD-Q4_K_XL, 4.22 GB. The repo's other
      # quant is UD-Q2_K_XL (3.22 GB); the mmproj-*.gguf files are vision
      # encoders and the MTP/ ones speculative-decoding drafts — neither is
      # needed for text generation.
      default = "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf";
      description = "GGUF file within the repo (change to pick another quant).";
    };
    littleCoderGpu = mkEnableOption ''
      GPU offload for llama-server: a Vulkan llama.cpp plus a wrapper that
      wires in the host NVIDIA driver. Needs a driver with Vulkan support and
      roughly 6GB of free VRAM for the default quant at an 8K context
    '';
    littleCoderGpuLayers = mkOption {
      type = types.int;
      default = 99;
      description = ''
        Layers offloaded to the GPU (llama-server -ngl) when littleCoderGpu
        is on. 99 means "all"; lower it if the model does not fit in VRAM.
      '';
    };
  };

  config = mkIf cfg.enableLittleCoder {
    # llama-cpp provides llama-server: little-coder does not bundle a GGUF
    # runtime — it talks OpenAI-compatible HTTP to 127.0.0.1:8888 (its
    # llamacpp provider default), which zsh/little-coder.zsh starts lazily.
    # This llama-cpp comes from nixpkgs-unstable via the overlay in flake.nix:
    # 25.05's b5311 knows neither the `gemma4` architecture the default model
    # below uses nor its `gemma3n` predecessor. Check that overlay's comment
    # before changing the model.
    # With GPU on, the wrapper takes priority for `llama-server` (hiPrio
    # settles the profile collision) while llamaCpp still provides llama-cli
    # and friends, unwrapped.
    home.packages = [ littleCoder llamaCpp ]
      ++ optional cfg.littleCoderGpu (hiPrio llamaServerGpuWrapper);

    # Read by zsh/little-coder.zsh; swap models via the options above (or by
    # overriding these vars in ~/.zshrc.local) without touching the helpers.
    home.sessionVariables = {
      LITTLE_CODER_GGUF = modelPath;
      # pi requires *some* value for local providers; the server ignores it.
      LLAMACPP_API_KEY = "noop";
    } // optionalAttrs cfg.littleCoderGpu {
      # Unset on CPU machines: the helper then passes no -ngl at all, which is
      # what a CPU build expects.
      LITTLE_CODER_NGL = toString cfg.littleCoderGpuLayers;
    };

    # little-coder's user override file (resolved at
    # ~/.config/little-coder/models.json): registers the served Gemma under
    # the stable handle llamacpp/gemma and makes it the first-run default.
    # llama.cpp serves whichever GGUF is loaded, so the id is just a handle.
    home.file.".config/little-coder/models.json".text = builtins.toJSON {
      default = "llamacpp/gemma";
      providers.llamacpp = {
        api = "openai-completions";
        baseUrl = "http://127.0.0.1:8888/v1";
        apiKey = "LLAMACPP_API_KEY";
        models = [
          {
            id = "gemma";
            name = "Gemma 4 E4B QAT (local llama.cpp)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 32768;
            maxTokens = 4096;
            cost = { input = 0; output = 0; cacheRead = 0; cacheWrite = 0; };
          }
        ];
      };
    };

    # Resume-capable, idempotent model download (multi-GB): skip when
    # present, curl -C - into a .part file, atomic mv on success,
    # warn-and-continue on failure like installLocalScribe.
    home.activation.downloadLittleCoderModel = hm.dag.entryAfter [ "writeBoundary" ] ''
      (
        f="${modelPath}"
        if [ -f "$f" ]; then
          echo "little-coder model already present: $f"
        else
          url="https://huggingface.co/${cfg.littleCoderModelRepo}/resolve/main/${cfg.littleCoderModelFile}"
          echo "Downloading little-coder model (multi-GB, resumable): $url"
          run mkdir -p "${modelDir}"
          $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fL -C - -o "$f.part" "$url"
          $DRY_RUN_CMD mv "$f.part" "$f"
        fi
      ) || echo "Warning: little-coder model download failed (URL above), continuing" >&2
    '';
  };
}
