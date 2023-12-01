{
  description = "native-link";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { flake-parts, crane, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = [ inputs.pre-commit-hooks.flakeModule ];
      perSystem = { config, self', inputs', pkgs, system, ... }:
        let
          llvmPackages = pkgs.llvmPackages_16;

          # This toolchain uses Clang as compiler, Mold as linker, libc++ as C++
          # standard library and compiler-rt as compiler runtime. Resulting
          # rust binaries depend dynamically linked on the nixpkgs distribution
          # of glibc. C++ binaries additionally depend dynamically on libc++,
          # libunwind and libcompiler-rt. Due to a bug we also depend on
          # libgcc_s.
          #
          # TODO(aaronmondal): At the moment this toolchain is only used for
          # the Cargo build. The Bazel build uses a different mostly hermetic
          # LLVM toolchain. We should merge the two by generating the Bazel
          # cc_toolchain from this stdenv. This likely requires a rewrite of
          # https://github.com/bazelbuild/bazel-toolchains as the current
          # implementation has poor compatibility with custom container images
          # and doesn't support generating toolchain configs from image
          # archives.
          #
          # TODO(aaronmondal): Due to various issues in the nixpkgs LLVM
          # toolchains we're not getting a pure Clang/LLVM toolchain here. My
          # guess is that the runtimes were not built with the degenerate
          # LLVM toolchain but with the regular GCC stdenv from nixpkgs.
          #
          # For instance, outputs depend on libgcc_s since libcxx seems to have
          # been was built with a GCC toolchain. We're also not using builtin
          # atomics, or at least we're redundantly linking libatomic.
          #
          # Fix this as it fixes a large number of issues, including better
          # cross-platform compatibility, reduced closure size, and
          # static-linking-friendly licensing. This requires building the llvm
          # project with the correct multistage bootstrapping process.
          customStdenv = pkgs.useMoldLinker (
            pkgs.overrideCC (
              llvmPackages.libcxxStdenv.override {
                targetPlatform.useLLVM = true;
              }
            )
            llvmPackages.clangUseLLVM
          );

          craneLib = crane.lib.${system};

          src = pkgs.lib.cleanSourceWith {
            src = craneLib.path ./.;
            filter = path: type:
              (builtins.match "^.+/data/SekienAkashita\\.jpg" path != null) ||
              (craneLib.filterCargoSources path type);
          };

          commonArgs = {
            inherit src;
            strictDeps = true;
            buildInputs = [ ];
            nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.cacert ];
            stdenv = customStdenv;
          };

          # Additional target for external dependencies to simplify caching.
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          native-link = craneLib.buildPackage (commonArgs
            // {
            inherit cargoArtifacts;
          });

          hooks = import ./tools/pre-commit-hooks.nix { inherit pkgs; };

          publish-ghcr = pkgs.writeShellScriptBin "publish-ghcr" ''
            set -xeuo pipefail

            echo $GHCR_PASSWORD | ${pkgs.skopeo}/bin/skopeo \
              login \
              --username=$GHCR_USERNAME \
              --password-stdin \
              ghcr.io

            # Commit hashes would not be a good choice here as they are not
            # fully dependent on the inputs to the image. For instance, amending
            # nothing would still lead to a new hash. Instead we use the
            # derivation hash as the tag so that the tag is reused if the image
            # didn't change.
            IMAGE_TAG=$(nix eval .#image.imageTag --raw)

            TAGGED_IMAGE=''${GHCR_REGISTRY}/''${GHCR_IMAGE_NAME}:''${IMAGE_TAG}

            $(nix build .#image --print-build-logs --verbose) \
              && ./result \
              | ${pkgs.zstd}/bin/zstd \
              | ${pkgs.skopeo}/bin/skopeo \
                copy \
                docker-archive:/dev/stdin \
                docker://''${TAGGED_IMAGE}

            echo $GHCR_PASSWORD | ${pkgs.cosign}/bin/cosign \
              login \
              --username=$GHCR_USERNAME \
              --password-stdin \
              ghcr.io

            ${pkgs.cosign}/bin/cosign \
              sign \
              --yes \
              ''${GHCR_REGISTRY}/''${GHCR_IMAGE_NAME}@$( \
                ${pkgs.skopeo}/bin/skopeo \
                  inspect \
                  --format "{{ .Digest }}" \
                  docker://''${TAGGED_IMAGE} \
            )


            # ${pkgs.cosign}/bin/cosign \
            #   sign \
            #   --yes \
            #   --key env://COSIGN_PRIVATE_KEY \
            #   ''${GHCR_REGISTRY}/''${GHCR_IMAGE_NAME}@$( \
            #     ${pkgs.skopeo}/bin/skopeo \
            #       inspect \
            #       --format "{{ .Digest }}" \
            #       docker://''${TAGGED_IMAGE} \
            # )
          '';

          # Since we're using nix inside this script we need to run it via
          # `nix run .#local-image-test`
          local-image-test = pkgs.writeShellScriptBin "local-image-test" ''
            set -xeuo pipefail

            # Commit hashes would not be a good choice here as they are not
            # fully dependent on the inputs to the image. For instance, amending
            # nothing would still lead to a new hash. Instead we use the
            # derivation hash as the tag so that the tag is reused if the image
            # didn't change.
            IMAGE_TAG=$(nix eval .#image.imageTag --raw)

            $(nix build .#image --print-build-logs --verbose) \
              && ./result \
              | docker load

            # Ensure that the image has minimal closure size.
            CI=1 ${pkgs.dive}/bin/dive \
              native-link:''${IMAGE_TAG} \
              --highestWastedBytes=0
          '';
        in
        {
          packages = {
            inherit publish-ghcr local-image-test;
            default = native-link;
            image = pkgs.dockerTools.streamLayeredImage {
              name = "native-link";
              contents = [
                native-link
                pkgs.dockerTools.caCertificates
              ];
              config = {
                Entrypoint = [ "/bin/cas" ];
              };
            };
          };
          checks = {
            # TODO(aaronmondal): Fix the tests.
            # tests = craneLib.cargoNextest (commonArgs
            #   // {
            #   inherit cargoArtifacts;
            #   cargoNextestExtraArgs = "--all";
            #   partitions = 1;
            #   partitionType = "count";
            # });
          };
          pre-commit.settings = { inherit hooks; };
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              # Development tooling goes here.
              pkgs.cargo
              pkgs.rustc
              pkgs.pre-commit
              pkgs.bazel
              pkgs.awscli2
              pkgs.skopeo
              pkgs.dive
              pkgs.cosign

              # Additional tools from within our development environment.
              local-image-test
            ];
            shellHook = ''
              # Generate the .pre-commit-config.yaml symlink when entering the
              # development shell.
              ${config.pre-commit.installationScript}

              # The Bazel and Cargo builds in nix require a Clang toolchain.
              # TODO(aaronmondal): The Bazel build currently uses the
              #                    irreproducible host C++ toolchain. Provide
              #                    this toolchain via nix for bitwise identical
              #                    binaries across machines.
              export CC=clang
            '';
          };
        };
    };
}
