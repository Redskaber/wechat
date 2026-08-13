# @path: wechat/flake.nix
# @author: redskaber
# @datetime: 2026-08-12
# @description: Production-ready Nix flake for Tencent WeChat (cross-platform)
# @reference: https://nix.dev/manual/nix/2.33/command-ref/new-cli/nix3-flake.html
#
# Supported platforms:
#   - x86_64-linux    (WeChatLinux_x86_64.deb)
#   - aarch64-linux   (WeChatLinux_arm64.deb)
#   - x86_64-darwin   (WeChatMac_*.dmg universal)
#   - aarch64-darwin  (WeChatMac_*.dmg universal)
#
# Usage:
#   nix run .#wechat                          # run WeChat on current system
#   nix build .#wechat                        # build into ./result
#   nix build .#packages.x86_64-linux.wechat   # explicit system
#   nix run .#update-sources                   # refresh sources.nix from upstream

{
  description = "Nix Flake for Tencent WeChat (auto-updated sources, cross-platform)";

  inputs = {
    # Use tarball URL to avoid GitHub API rate-limiting (403 on /repos/.../commits).
    nixpkgs.url = "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz";
  };

  outputs = { self, nixpkgs }:
    let
      # All platforms WeChat ships binaries for.
      # NOTE: x86_64-darwin was dropped by nixpkgs 26.11; WeChat's universal
      # .dmg still supports Intel Macs at the binary level, but our packaging
      # follows nixpkgs and only targets aarch64-darwin for macOS.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Import nixpkgs with allowUnfree so we can pull in things like
      # nss, krb5 (which are MIT/MPL licensed but classified unfree in
      # some nixpkgs revisions), and so the resulting derivation can
      # inherit an unfree license cleanly.
      pkgsFor = system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      sources = import ./sources.nix;

      # Choose the right package.nix based on host platform.
      # For Linux this returns a `buildFHSEnv` derivation (wechat, the
      # outer FHS-wrapped launcher). The inner `wechat-unwrapped` is
      # accessible via the `unwrapped` passthru attribute on the result.
      packageFor = system:
        let pkgs = pkgsFor system;
        in if pkgs.stdenv.isLinux then
          pkgs.callPackage ./package-linux.nix {
            inherit pkgs system sources;
          }
        else if pkgs.stdenv.isDarwin then
          pkgs.callPackage ./package-darwin.nix {
            inherit pkgs system sources;
          }
        else
          throw "Unsupported system: ${system}";
    in {
      packages = forAllSystems (system:
        let pkg = packageFor system;
        in {
          default = pkg;
          wechat = pkg;
          # Expose the unwrapped (non-FHS) build for debugging / power users
          # who want to inspect the patched ELF without the FHS namespace.
          wechat-unwrapped = pkg.passthru.unwrapped or pkg;
        });

      apps = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          # Daily auto-update helper. Runs ./update.sh which probes the
          # official Tencent endpoints and rewrites sources.nix.
          update-sources = {
            type = "app";
            program = "${pkgs.writeShellScript "update-sources" ''
              exec ${./update.sh}
            ''}";
          };
          # Convenience launcher so `nix run .#wechat` works.
          wechat = {
            type = "app";
            program = "${packageFor system}/bin/wechat";
          };
        });

      # Surface the sources overlay for downstream consumers (e.g. NUR).
      # We expose `wechat` for the calling system via the overlay's `prev.stdenv`
      # so users can do: `final.callPackage ./wechat { pkgs = final; }` and
      # get a working build for their system.
      overlays.default = final: prev: {
        wechat = prev.callPackage ./package-linux.nix {
          inherit sources;
          pkgs = final;
          system = final.stdenv.hostPlatform.system;
        };
      };

      # Allow `nix flake check` to validate the flake.
      checks = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          build = packageFor system;
        });
    };
}
