{
  description = ''
    Golangci-lint v1 and v2 flake.
    Exposes packages for use in NixOS configurations and dev shells.
  '';

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    golangci1-src = {
      url = "github:golangci/golangci-lint?ref=v1.64.8";
      flake = false;
    };

    golangci2-src = {
      url = "github:golangci/golangci-lint?ref=v2.5.0";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, ... }:
    let
      forEachSystem =
        f:
        inputs.nixpkgs.lib.genAttrs inputs.nixpkgs.lib.systems.flakeExposed (
          system: f inputs.nixpkgs.legacyPackages.${system}
        );

      perSystem =
        system: pkgs:
        let
          lib = pkgs.lib;
          pkgsUnstable = import inputs.nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };

          platform =
            {
              "x86_64-linux" = {
                os = "linux";
                arch = "amd64";
              };
              "aarch64-linux" = {
                os = "linux";
                arch = "arm64";
              };
              "x86_64-darwin" = {
                os = "darwin";
                arch = "amd64";
              };
              "aarch64-darwin" = {
                os = "darwin";
                arch = "arm64";
              };
            }
            .${pkgs.stdenv.hostPlatform.system}
            or (throw "Unsupported system: ${pkgs.stdenv.hostPlatform.system}");

          mkGolangciLintFromPrebuiltBinaryDerivation =
            { version, sha256s }:
            pkgs.stdenv.mkDerivation {
              pname = "golangci-lint";
              inherit version;

              src = pkgs.fetchurl {
                url = "https://github.com/golangci/golangci-lint/releases/download/v${version}/golangci-lint-${version}-${platform.os}-${platform.arch}.tar.gz";
                hash =
                  sha256s.${pkgs.stdenv.hostPlatform.system}
                    or (throw "Missing hash for ${pkgs.stdenv.hostPlatform.system} (golangci-lint v${version})");
              };

              phases = [
                "unpackPhase"
                "installPhase"
              ];
              installPhase = ''
                set -eu
                mkdir -p "$out/bin"
                BIN="golangci-lint"
                if [ ! -e "$BIN" ]; then
                  if [ -e "bin/golangci-lint" ]; then
                    BIN="bin/golangci-lint"
                  else
                    echo "Contents of source root (for debugging):"
                    ls -la
                    echo "Could not find golangci-lint binary in source root"
                    exit 1
                  fi
                fi
                install -m 0755 "$BIN" "$out/bin/golangci-lint-v${lib.versions.major version}"
              '';
            };

          mkGolangciLintFromSourceDerivation =
            {
              src,
              version,
              vendorHash
            }:
            pkgs.buildGoModule {
              pname = "golangci-lint";
              inherit version src;

              # OS+arch-independent value
              inherit vendorHash; # use pkgs.lib.fakeHash; then try to build and copy from error e.g. nix build .#packages.aarch64-darwin.golangci-lint-v2

              subPackages = [ "cmd/golangci-lint" ];

              ldflags = [
                "-s"
                "-w"
                "-X main.version=${version}"
                "-X main.commit=${src.rev or "unknown"}"
                "-X main.date=1970-01-01"
              ];

              postInstall = ''
                mv "$out/bin/golangci-lint" "$out/bin/golangci-lint-v${lib.versions.major version}"
              '';
            };

          golangci_lint_v1_from_prebuilt = mkGolangciLintFromPrebuiltBinaryDerivation {
            version = "1.64.8";
            sha256s = {
              x86_64-linux = ""; # fill me
              aarch64-linux = "sha256-<fill-me>";
              x86_64-darwin = "sha256-<fill-me>";
              aarch64-darwin = "sha256-cFQ9IeWwKpQHm+iqESZ6WwYIZVg+M3/naNObXT4vrx8=";
            };
          };

          golangci_lint_v2_from_prebuilt = mkGolangciLintFromPrebuiltBinaryDerivation {
            version = "2.5.0";
            sha256s = {
              x86_64-linux = ""; # fill me
              aarch64-linux = "sha256-<fill-me>";
              x86_64-darwin = "";
              aarch64-darwin = "sha256-Czy9wqJHL2C1OOvMsbLhrl2TigUcAQWRqmjG79NwZnI=";
            };
          };

          golangci_lint_v1_from_source = mkGolangciLintFromSourceDerivation {
            src = inputs.golangci1-src;
            version = "1.64.8";
            vendorHash = "sha256-i7ec4U4xXmRvHbsDiuBjbQ0xP7xRuilky3gi+dT1H10=";
          };

          golangci_lint_v2_from_source = mkGolangciLintFromSourceDerivation {
            src = inputs.golangci2-src;
            version = "2.5.0";
            vendorHash = "sha256-QEYbFz7SJxLMblkNqaRLDn/PO+mtSPvNYiEUmZh0sLQ=";
          };

          mkDefaultLintDerivation =
            drv: binName:
            pkgs.symlinkJoin {
              name = "golangci-lint";
              paths = [ drv ];
              postBuild = ''
                rm -f $out/bin/golangci-lint
                ln -s $out/bin/${binName} $out/bin/golangci-lint
              '';
            };

          golangci_lint_v1_default = mkDefaultLintDerivation golangci_lint_v1_from_source "golangci-lint-v1";
          golangci_lint_v2_default = mkDefaultLintDerivation golangci_lint_v2_from_source "golangci-lint-v2";

          deployScript = pkgs.writeShellScriptBin "deploy" ''
            set -euo pipefail
            REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
            SCRIPT="''${REPO_ROOT}/scripts/deploy-local-kind.sh"

            if [ ! -f "$SCRIPT" ]; then
              echo "❌ Deploy script not found at: $SCRIPT"
              echo "   Make sure you're in the dtp-orchestration repository"
              exit 1
            fi

            exec "$SCRIPT" "$@"
          '';

          extraPackages = [
            pkgsUnstable.github-copilot-cli
            pkgsUnstable.bats
            pkgsUnstable.kubectl
            pkgsUnstable.kind
            pkgsUnstable.kubernetes-helm
            pkgsUnstable.skaffold
            deployScript
          ];
        in
        {
          packages = {
            golangci-lint-v1 = golangci_lint_v1_from_source; # nix build .#packages.aarch64-darwin.golangci-lint-v1
            golangci-lint-v2 = golangci_lint_v2_from_source; # nix build .#packages.aarch64-darwin.golangci-lint-v2
            golangci-lint = golangci_lint_v2_default; # nix build .#packages.aarch64-darwin.golangci-lint
            default = golangci_lint_v2_default; # nix build .#packages.aarch64-darwin.default
          };

          devShells = {
            v1 = pkgs.mkShellNoCC {
              packages = [ golangci_lint_v1_default ] ++ extraPackages;
            };
            v2 = pkgs.mkShellNoCC {
              packages = [ golangci_lint_v2_default ] ++ extraPackages;
            };
            default = pkgs.mkShellNoCC {
              packages = [ golangci_lint_v2_default ] ++ extraPackages;
            };
          };
        };
    in
    {
      packages = forEachSystem (pkgs: (perSystem pkgs.system pkgs).packages);
      devShells = forEachSystem (pkgs: (perSystem pkgs.system pkgs).devShells);
    };
}
