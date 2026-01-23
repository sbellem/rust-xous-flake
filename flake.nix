{
  description = "Rust toolchain with riscv32imac-unknown-xous-elf target support";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2511.906247";
    rust-overlay.url = "https://flakehub.com/f/oxalica/rust-overlay/0.1.2051";
    crane.url = "github:ipetkov/crane/0bda7e7d005ccb5522a76d11ccfbf562b71953ca";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      crane,
    }:
    let
      rustVersion = "1.93.0";

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ (import rust-overlay) ];
            };
          }
        );
    in
    {
      packages = forAllSystems (
        { pkgs }:
        let
          baseRustToolchain = pkgs.rust-bin.stable."1.93.0".default.override {
            targets = [ "riscv32imac-unknown-none-elf" ];
            extensions = [ "rust-src" "rustfmt" "clippy" ];
          };

          craneLib = (crane.mkLib pkgs).overrideToolchain baseRustToolchain;

          rustXousSrc = pkgs.fetchFromGitHub {
            owner = "betrusted-io";
            repo = "rust";
            rev = "2ae864f7d4d42c73ab05f5e01265ea31ae81a86e";
            sha256 = "sha256-+iLFMy78f5xgw22fHPKmTy5WQonYbsi6Ms9tWeh6uxI=";
            fetchSubmodules = true;
          };

          # RISC-V cross compiler for building compiler-builtins
          riscvCC = pkgs.pkgsCross.riscv32-embedded.stdenv.cc;

          # Vendor Cargo dependencies manually
          cargoVendorDir = pkgs.stdenv.mkDerivation {
            name = "xous-sysroot-cargo-vendor";
            src = rustXousSrc;
            nativeBuildInputs = [ baseRustToolchain pkgs.cacert ];

            # Skip phases we don't need
            dontConfigure = true;
            dontBuild = false;
            dontFixup = true;  # FOD cannot have store references

            buildPhase = ''
              export HOME=$PWD
              export CARGO_HOME=$PWD/.cargo
              mkdir -p $CARGO_HOME

              # Enable nightly features - needed to parse Cargo.toml with public-dependency
              export RUSTC_BOOTSTRAP=1

              cd library
              # Vendor dependencies (Cargo.lock already exists in the repo)
              cargo vendor --manifest-path sysroot/Cargo.toml --locked > vendor-config
            '';

            installPhase = ''
              mkdir -p $out
              cp -r vendor $out/
            '';

            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-dIuw+8WhEpFMGbtJk8bWdbtMDIHa/1WkeeGCQD9uuFo=";
          };

          # Build the Xous sysroot (libstd for riscv32imac-unknown-xous-elf)
          xousSysroot = pkgs.stdenv.mkDerivation {
            pname = "xous-sysroot";
            version = rustVersion;
            src = rustXousSrc;

            nativeBuildInputs = [
              baseRustToolchain
              riscvCC
              pkgs.git
            ];

            # Skip all phases except build
            dontConfigure = true;
            dontFixup = true;

            CARGO_PROFILE_RELEASE_DEBUG = "0";
            CARGO_PROFILE_RELEASE_OPT_LEVEL = "3";
            CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS = "false";
            RUSTC_BOOTSTRAP = "1";
            RUSTFLAGS = "-Cforce-unwind-tables=yes -Cembed-bitcode=yes -Zforce-unstable-if-unmarked";
            __CARGO_DEFAULT_LIB_METADATA = "stablestd";
            CC = "${riscvCC}/bin/riscv32-none-elf-gcc";
            AR = "${riscvCC}/bin/riscv32-none-elf-ar";

            buildPhase = ''
              runHook preBuild

              export HOME=$PWD
              export CARGO_HOME=$PWD/.cargo
              mkdir -p $CARGO_HOME

              # Configure Cargo to use vendored dependencies
              cp -r ${cargoVendorDir}/vendor vendor
              cat > .cargo/config.toml <<EOF
              [source.crates-io]
              replace-with = "vendored-sources"

              [source.vendored-sources]
              directory = "$PWD/vendor"
              EOF

              # Set up cross compiler
              export RUST_COMPILER_RT_ROOT="$PWD/src/llvm-project/compiler-rt"

              # Verify compiler-rt exists
              if [ ! -d "$RUST_COMPILER_RT_ROOT" ]; then
                echo "ERROR: compiler-rt not found at $RUST_COMPILER_RT_ROOT"
                echo "Available in src/:"
                ls -la src/ || true
                exit 1
              fi

              cargo build \
                --target riscv32imac-unknown-xous-elf \
                -Zbinary-dep-depinfo \
                --release \
                --features "panic-unwind compiler-builtins-c compiler-builtins-mem" \
                --manifest-path "library/sysroot/Cargo.toml"

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/rustlib/riscv32imac-unknown-xous-elf/lib
              rustc --version | awk '{print $2}' > $out/lib/rustlib/riscv32imac-unknown-xous-elf/RUST_VERSION
              cp library/target/riscv32imac-unknown-xous-elf/release/deps/*.rlib \
                $out/lib/rustlib/riscv32imac-unknown-xous-elf/lib/

              runHook postInstall
            '';
          };

          mergedSysroot = pkgs.stdenv.mkDerivation {
            pname = "rust-sysroot-merged";
            version = rustVersion;
            dontUnpack = true;
            dontBuild = true;

            installPhase = ''
              mkdir -p $out/lib/rustlib

              # Copy everything from the base toolchain's sysroot
              cp -r ${baseRustToolchain}/lib/rustlib/* $out/lib/rustlib

              # Add the Xous target
              cp -r ${xousSysroot}/lib/rustlib/riscv32imac-unknown-xous-elf $out/lib/rustlib
            '';
          };

          rustToolchain = pkgs.symlinkJoin {
            name = "rust-${rustVersion}-xous";
            paths = [ baseRustToolchain ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              # Wrap rustc to use our merged sysroot
              rm $out/bin/rustc
              makeWrapper ${baseRustToolchain}/bin/rustc $out/bin/rustc \
                --add-flags "--sysroot ${mergedSysroot}"

              # Wrap cargo to use our wrapped rustc
              rm $out/bin/cargo
              makeWrapper ${baseRustToolchain}/bin/cargo $out/bin/cargo \
                --set RUSTC "$out/bin/rustc"
            '';
          };
        in
        {
          inherit xousSysroot mergedSysroot rustToolchain;
          default = rustToolchain;
        }
      );

      # Export an overlay for use in other flakes
      overlays.default = final: prev: {
        rustToolchainXous = self.packages.${final.system}.rustToolchain;
      };

      devShells = forAllSystems (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = [
              self.packages.${pkgs.system}.rustToolchain
              pkgs.pkg-config
              pkgs.openssl
            ];
            shellHook = ''
              echo "Rust ${rustVersion} with Xous sysroot"
              echo "Available targets:"
              echo "  - riscv32imac-unknown-none-elf"
              echo "  - riscv32imac-unknown-xous-elf"
            '';
          };
        }
      );
    };
}
