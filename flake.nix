{
  description = ''
    Use `nix develop` or `nix develop -c $SHELL` to activate me.

    Strategies to enable toggling between golangci-lint versions:
    1. Proxy script wrapper to serve as dispatcher to v1 or v2
    2. Helper shell function that takes version as arg to swap out a private bin symlink.
    3. Split dev shells and choose at nix develop time: nix develop .#v1 | nix develop .#v2

    This flake uses strategy 3.
  '';
  inputs = {
    systems.url = "github:nix-systems/default";
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

    # go_test_help = ''
    #   echo "go help test"
    #   echo "go help testflags"
    #   echo "go test -failfast -fullpath -list"
    #   echo "go test -json | tparse -all"
    #   echo "regex test uses substring match"
    #   echo "go test -v -run "ASDY_22191" ./pkg/<somepackage>
    # '';
  };
  outputs =
    inputs@{
      self,
      nixpkgs,
      systems,
      # note: we don't need to destructure nixpkgs-unstable here; we'll use inputs."nixpkgs-unstable"
      # but we do need an ellipsis to make outputs accept extra inputs like nixpkgs-unstable
      ...
    }:
    let
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs (import systems) (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };

            pkgsUnstable = import inputs."nixpkgs-unstable" {
              inherit system;
              config.allowUnfree = true;
            };

          }
        );
    in
    {
      devShells = forEachSystem (
        {
          pkgs,
          pkgsUnstable,
          system,
        }:
        let
          lib = pkgs.lib;

          # platform mapping + mkGolangciLintDerivation stay as you already have them
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

          # (fetches tarball, unpacks, installs the real binary)
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
              meta.platforms = [ pkgs.stdenv.hostPlatform.system ];
            };

          # (builds golangci-lint from source)
          mkGolangciLintFromSourceDerivation =
            {
              src,
              version,
            }:
            pkgs.buildGoModule {
              pname = "golangci-lint";
              inherit version src;

              vendorHash = null;

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

              meta.platforms = lib.platforms.unix;
            };

          # Your two versions (fill missing hashes as needed)
          golangci_lint_v1 = mkGolangciLintFromPrebuiltBinaryDerivation {
            version = "1.64.8";
            sha256s = {
              x86_64-linux = ""; # fill me
              aarch64-linux = "sha256-<fill-me>";
              x86_64-darwin = "sha256-<fill-me>";
              aarch64-darwin = "sha256-cFQ9IeWwKpQHm+iqESZ6WwYIZVg+M3/naNObXT4vrx8=";
            };
          };

          golangci_lint_v2 = mkGolangciLintFromPrebuiltBinaryDerivation {
            version = "2.5.0";
            sha256s = {
              x86_64-linux = ""; # fill me
              aarch64-linux = "sha256-<fill-me>";
              x86_64-darwin = "";
              aarch64-darwin = "sha256-Czy9wqJHL2C1OOvMsbLhrl2TigUcAQWRqmjG79NwZnI=";
            };
          };

          # Source-based versions using flake inputs (no manual hashes needed)
          golangci_lint_v1_from_source = mkGolangciLintFromSourceDerivation {
            src = inputs.golangci1-src;
            version = "1.64.8";
          };

          golangci_lint_v2_from_source = mkGolangciLintFromSourceDerivation {
            src = inputs.golangci2-src;
            version = "2.5.0";
          };

          # to solve the uniqueness of binary names problem in a reusable way: 
          # a tiny wrapper that exposes the chosen version as "golangci-lint"
          # wraps an existing package (no fetching/building of the tool itself)
          # It creates a tiny Nix package (a "derivatoin") that installs an executable named golangci-lint that simply executes an executable from another derivation.
          mkDefaultLintDerivation =
            drv: binName:
            pkgs.writeShellScriptBin "golangci-lint" ''
                set -euo pipefail

                target="${drv}/bin/${binName}"
                if [ ! -x "$target" ]; then
                  echo "golangci-lint wrapper error: $target not found or not executable" >&2
                  exit 127
                fi

                exec -a golangci-lint "${drv}/bin/${binName}" "$@"
                # -a golangci-lint sets argv[0] (process name) to golangci-lint.
                # "${drv}/bin/${binName}" is the fully-qualified store path to the actual binary
                # "$@" forwards all user-provided arguments.
            '';

          golangci_lint_v1_default = mkDefaultLintDerivation golangci_lint_v1 "golangci-lint-v1";
          golangci_lint_v2_default = mkDefaultLintDerivation golangci_lint_v2 "golangci-lint-v2";

          # -- DRY shellHook: shared between all shells --
          commonShellHook = packageNames: ''
            echo "🔧 Activated nix shell for system: ${system}"
            echo "📦 Available packages: ${packageNames}"
            echo "🧑🏼‍💻 Available executables:"
            echo "$PATH" | tr ':' '\n' | grep '^/nix/store' | xargs -I{} sh -c 'ls -1 "{}" 2>/dev/null || true' | xargs || true
            echo ""
            echo "💡 Tip: Run 'deploy' from the repository root to set up a local kind cluster with dtp-orchestration"
          '';

          # -- helper to build a shell for a chosen version --
          mkDevShell =
            {
              drv,
              defaultWrapper,
              extraPackages ? [ ],
            }:
            let
              pkgsList = [
                drv
                defaultWrapper
              ]
              ++ extraPackages;
              packageNames = builtins.concatStringsSep " " (map (p: p.name) pkgsList);
            in
            pkgs.mkShellNoCC {
              packages = pkgsList;
              shellHook = commonShellHook packageNames;
            };

          # Create deploy wrapper script
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

          extraPackages = with pkgsUnstable; [
            github-copilot-cli
            bats
            kubectl
            kind
            kubernetes-helm
            skaffold
          ]
          ++ [ deployScript ];
        in
        {
          # Mutually exclusive shells where "golangci-lint" maps to one version
          v1 = mkDevShell {
            drv = golangci_lint_v1;
            defaultWrapper = golangci_lint_v1_default;
            inherit extraPackages;
          };
          v2 = mkDevShell {
            drv = golangci_lint_v2;
            defaultWrapper = golangci_lint_v2_default;
            inherit extraPackages;
          };

          # Optional: pick one as default for `nix develop` without selector
          default = self.devShells.${system}.v2;
        }
      );
    };
}
