# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

> Maintainer: **redskaber** ([@redskaber](https://github.com/redskaber))

## [1.0.1] - 2026-08-12

### Fixed
- **Linux runtime: `/usr/bin/lsblk: No such file or directory`** — WeChat internally
  `popen()`s commands at absolute FHS paths (`/usr/bin/lsblk`, `/usr/bin/udevadm`,
  `/usr/bin/ps`, …). NixOS has no `/usr/bin/` by default, so these calls failed at
  runtime. Fixed by wrapping the binary in `buildFHSEnv` so a real `/usr/bin/`
  tree (populated with `util-linux`, `systemd`, `procps`, `iproute2`, `coreutils`,
  `gawk`, `gnugrep`, `gnused`, `findutils`, `which`, `pciutils`, `usbutils`,
  `hostname`, `xdg-utils`, `pcsclite`, `nettools`, `diffutils`, `file`,
  `iputils`) is visible inside the bubblewrap namespace.

### Changed
- Refactored `package-linux.nix` into a two-layer build:
  - Layer 1: `wechat-unwrapped` — unpacks the `.deb`, runs `autoPatchelfHook`,
    installs a launcher that sets up `LD_LIBRARY_PATH` / `FONTCONFIG_FILE` / XKB.
  - Layer 2: `wechat` — `buildFHSEnv` wrapping layer 1, providing the FHS
    namespace with `/usr/bin/lsblk` etc.
- Exposed `packages.${system}.wechat-unwrapped` for debugging / power users who
  want to inspect the patched ELF payload without the FHS namespace.
- Added `passthru.unwrapped` on the FHS derivation pointing to layer 1.
- Desktop entry `Exec=` line now uses the bare command name (`wechat`) so it
  works both inside and outside the FHS namespace.

## [1.0.0] - 2026-08-12

### Added
- Initial release of `wechat` flake.
- **Linux** derivation (`package-linux.nix`) based on the upstream `.deb`:
  - `x86_64-linux` (WeChatLinux_x86_64.deb) — version 4.1.1.8
  - `aarch64-linux` (WeChatLinux_arm64.deb) — version 4.1.1.8
  - Full autoPatchelf coverage of all ELF binaries and bundled `.so` files
  - Comprehensive runtime dependency list (X11, XCB, PulseAudio, NSS, Kerberos, DBus, fonts)
  - `makeBinaryWrapper`-based launcher that sets `LD_LIBRARY_PATH`, `FONTCONFIG_FILE`,
    `GDK_PIXBUF_MODULE_FILE`, `XDG_DATA_DIRS`, etc.
  - Properly installed `.desktop` entry and hicolor icons
- **macOS** derivation (`package-darwin.nix`) based on the upstream universal `.dmg`:
  - `aarch64-darwin` (Apple Silicon) — version 4.1.12
  - Uses `hdiutil` on macOS host, `p7zip` two-pass extraction on Linux
- **Auto-update script** (`update.sh`):
  - Probes the official Tencent CDN endpoints
  - Extracts Linux version from `.deb` `control` file
  - Parses macOS version from `.dmg` filename
  - Computes SHA256 via `nix-prefetch-url` (or `nix hash file` as fallback)
  - Atomically rewrites `sources.nix`
- **CI/CD** (`.github/workflows/daily-update.yml`):
  - Runs every day at 03:00 Asia/Shanghai (UTC 19:00)
  - Manual `workflow_dispatch` trigger also supported
  - Creates a PR with the regenerated `sources.nix` when changes are detected
- **`verify.sh`** end-to-end verification script (flake check + update + build + smoke test)
- Comprehensive `README.md` documentation
- MIT `LICENSE` for the packaging glue code

### Notes
- The WeChat binaries themselves remain under Tencent's own EULA — this project
  only provides build glue and does not redistribute the upstream binaries.
- `x86_64-darwin` is **not** supported because nixpkgs 26.11 dropped support
  for Intel macOS. The universal `.dmg` still covers Intel Macs at the binary
  level, but our packaging follows nixpkgs and only targets `aarch64-darwin`
  for macOS.
- The bundled `WeChatAppEx` subprocess (mini-app runtime) requires the
  bundled `libtxffmpeg.so` to be on `LD_LIBRARY_PATH`; our wrapper handles
  this automatically.
