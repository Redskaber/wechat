# @path: wechat/package-linux.nix
# @author: redskaber
# @datetime: 2026-08-12
# @description: Linux derivation for Tencent WeChat built from the official .deb.
#
# Build flow (two-layer):
#   Layer 1: `wechat-unwrapped` (mkDerivation)
#     1. fetchurl the .deb (sources.linux.${system})
#     2. ar x + tar -xvf to unpack
#     3. autoPatchelfHook patches RPATHs and interpreter on all ELF files
#     4. installPhase copies opt/wechat, icons, desktop file, wraps the main
#        binary with required LD_LIBRARY_PATH and a few necessary env vars.
#
#   Layer 2: `wechat` (buildFHSEnv)
#     WeChat internally `popen()`s commands at absolute FHS paths like
#     `/usr/bin/lsblk`, `/usr/bin/udevadm`, etc. (the strings are in the
#     encrypted resource files, not visible in `strings`). NixOS has no
#     `/usr/bin/` by default, so we wrap the whole app in an FHS namespace
#     where these paths actually exist.
#     - targetPkgs: util-linux (lsblk), systemd (udevadm), procps, coreutils,
#       iproute2, gawk, gnugrep, gnused, findutils, which + all runtime deps
#     - runScript: the unwrapped binary's launcher
#
# Tested on NixOS unstable (2026-08) for x86_64-linux and aarch64-linux.

{ pkgs, system, sources }:

let
  srcInfo = sources.linux.${system} or (throw "Unsupported Linux system: ${system}");
  version = sources.linux.version;

  # Runtime libraries the WeChat binary links against. This list was derived
  # by running `ldd opt/wechat/wechat` against the upstream deb.
  runtimeDeps = with pkgs; [
    # X11 core
    libX11
    libXau
    libXdmcp
    libXext
    libXfixes
    libXcomposite
    libXdamage
    libXrandr
    libXrender
    libXtst
    libXi
    libXcursor
    libxcb

    # XCB extensions (nixpkgs uses kebab-case camelCased names)
    xcbutil
    xcbutilimage
    xcbutilkeysyms
    xcbutilrenderutil
    xcbutilwm
    libxcb-cursor

    # Keyboard
    libxkbcommon
    libxkbfile

    # GL
    libGL
    libglvnd
    mesa

    # GTK / theme
    gtk3
    gdk-pixbuf
    glib
    pango
    cairo
    atk
    at-spi2-atk
    at-spi2-core
    fontconfig
    freetype

    # Audio (PulseAudio stack)
    pulseaudio
    alsa-lib
    libsndfile
    flac
    libogg
    libvorbis
    opus
    mpg123
    lame
    libasyncns

    # NSS / NSPR (libnss3.so etc.)
    nss
    nspr

    # Kerberos (nixpkgs package is `krb5` - it provides libgssapi_krb5.so etc.)
    krb5
    keyutils

    # DBus / udev / systemd
    dbus
    systemd

    # Compression
    zlib
    bzip2
    brotli
    zstd
    xz

    # Misc
    expat
    libpng
    libcap
    libuuid
    libxml2

    # Cryptography / TLS (used indirectly by some .so files)
    openssl

    # Icons / fonts runtime
    hicolor-icon-theme

    # Fonts required by WeChat for proper CJK rendering
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
  ];

  # FHS-only packages: command-line tools WeChat shells out to via absolute
  # paths. These are NOT linked into the binary's RPATH, so they don't need to
  # be in `runtimeDeps` - they just need to exist at `/usr/bin/...` inside
  # the FHS namespace.
  fhsCmdDeps = with pkgs; [
    util-linux       # /usr/bin/lsblk, /usr/bin/mount, /usr/bin/umount, ...
    procps           # /usr/bin/ps, /usr/bin/top, /usr/bin/sysctl, ...
    iproute2         # /usr/bin/ip, /usr/bin/ss, ...
    iputils          # /usr/bin/ping, /usr/bin/arping, ...
    procps           # /usr/bin/free, /usr/bin/uptime (often called)
    coreutils        # /usr/bin/ls, /usr/bin/cat, /usr/bin/cp, ...
    findutils        # /usr/bin/find, /usr/bin/xargs, ...
    gnugrep          # /usr/bin/grep
    gnused           # /usr/bin/sed
    gawk             # /usr/bin/awk
    which            # /usr/bin/which
    diffutils        # /usr/bin/diff
    file             # /usr/bin/file
    xdg-utils        # /usr/bin/xdg-open
    pcsclite         # smartcard / libpcsclite.so.1 (sometimes popped)
    pciutils         # /usr/bin/lspci (hardware enumeration)
    usbutils         # /usr/bin/lsusb
    nettools         # /usr/bin/netstat (legacy, sometimes called)
    hostname         # /usr/bin/hostname
  ];

  # autoPatchelfIgnoreMissingDeps: WeChat ships some libs that try to dlopen
  # system libs that may not be present in the sandbox (e.g. libgbm, libwayland).
  # We don't fail the build for those, the runtime wrapper provides them.
  #
  # libjack.so.0 is needed only by the VLC JACK audio output plugin - JACK is
  # an advanced audio system not commonly used on the desktop. The plugin will
  # simply fail to load at runtime if JACK isn't installed, which is fine.
  ignoredDeps = [
    "libwechat-wmpf.so"      # wechat plugin loader - loaded at runtime
    "libgbm.so.1"            # Wayland/EGL buffer mgr - optional, runtime-loaded
    "libwayland-client.so.0" # Wayland - optional, runtime-loaded
    "libwayland-server.so.0" # Wayland - optional, runtime-loaded
    "libjack.so.0"           # JACK audio - VLC plugin, rarely needed
  ];

  # ----------------------------------------------------------------- #
  # Layer 1: wechat-unwrapped                                         #
  # ----------------------------------------------------------------- #
  wechat-unwrapped = pkgs.stdenv.mkDerivation rec {
    pname = "wechat-unwrapped";
    inherit version;

    src = pkgs.fetchurl {
      url = srcInfo.url;
      sha256 = srcInfo.sha256;
    };

    nativeBuildInputs = with pkgs; [
      autoPatchelfHook
      dpkg
      makeWrapper
      wrapGAppsHook3   # for proper GTK / gsettings schemas registration
    ];

    buildInputs = runtimeDeps;

    # Tell autoPatchelf not to bail on optional runtime-loaded libs.
    autoPatchelfIgnoreMissingDeps = ignoredDeps;

    unpackPhase = ''
      runHook preUnpack
      ar x $src
      tar -xf data.tar.* --no-same-permissions --no-same-owner
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      # Main application payload.
      mkdir -p $out/share/wechat
      cp -av opt/wechat/* $out/share/wechat/

      # Desktop entry & icons (kept for the outer FHS derivation to symlink).
      mkdir -p $out/share/applications $out/share/icons/hicolor
      if [ -d usr/share/applications ]; then
        cp -av usr/share/applications/*.desktop $out/share/applications/ 2>/dev/null || true
      fi
      # The deb ships icons under usr/share/icons/hicolor/<size>/apps/wechat.png.
      # Copy them under our $out/share/icons/hicolor/<size>/apps/.
      if [ -d usr/share/icons/hicolor ]; then
        cp -av usr/share/icons/hicolor/* $out/share/icons/hicolor/ 2>/dev/null || true
      fi

      # Patch desktop file: point Exec at `wechat` (the FHS launcher installs
      # a wrapper at $out/bin/wechat that hosts can call directly). Icon is
      # set to the basename so hicolor theme lookup picks up our PNGs.
      find $out/share/applications -name "*.desktop" -exec sed -i \
        -e "s|^Exec=.*|Exec=wechat %U|" \
        -e "s|^Icon=.*|Icon=wechat|" \
        {} +

      # Layer-1 wrapper: sets LD_LIBRARY_PATH for ELF dynamic linker.
      # The outer FHS layer adds /usr/bin/* tools; this inner wrapper handles
      # the bundled-lib discovery (libtxffmpeg etc.) and XKB/fontconfig paths.
      mkdir -p $out/bin
      makeWrapper $out/share/wechat/wechat $out/bin/wechat-unwrapped \
        --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath runtimeDeps}:$out/share/wechat:$out/share/wechat/RadiumWMPF/runtime" \
        --set WECHAT_ROOT "$out/share/wechat" \
        --set QT_XKB_CONFIG_ROOT "${pkgs.xkeyboardconfig}/share/X11/xkb" \
        --set FONTCONFIG_FILE "${pkgs.fontconfig.out}/etc/fonts/fonts.conf" \
        --set GDK_PIXBUF_MODULE_FILE "${pkgs.gdk-pixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" \
        --set PULSE_PROP "application.name=WeChat" \
        --add-flags "--no-sandbox" \
        --add-flags "--enable-features=UseOzonePlatform" \
        --add-flags "--ozone-platform-hint=auto"

      runHook postInstall
    '';

    # Strip is fine; WeChat binaries are stripped already but autoPatchelf
    # may produce some additional .debug files we don't need.
    dontStrip = false;

    meta = with pkgs.lib; {
      description = "Tencent WeChat desktop client (Linux) - unpacked ELF payload";
      platforms = [ "x86_64-linux" "aarch64-linux" ];
      license = licenses.unfree;
      maintainers = with maintainers; [ redskaber ];
      sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    };
  };

  # ----------------------------------------------------------------- #
  # Layer 2: wechat (FHS env wrapping wechat-unwrapped)               #
  # ----------------------------------------------------------------- #
in pkgs.buildFHSEnv {
  pname = "wechat";
  inherit version;

  # targetPkgs: packages whose contents appear at /usr/bin, /usr/lib,
  # /usr/share etc. *inside* the FHS namespace. We pull in:
  #   - all runtime deps (so their libs land at /usr/lib and bin at /usr/bin)
  #   - all FHS-only command deps (util-linux's lsblk, systemd's udevadm, ...)
  targetPkgs = pkgs: runtimeDeps ++ fhsCmdDeps;

  # multiPkgs: 32-bit + 64-bit libs (we only ship 64-bit, leave empty).
  multiPkgs = pkgs: [ ];

  # The script that actually runs inside the FHS namespace.
  # We call the unwrapped binary's launcher which already sets up
  # LD_LIBRARY_PATH / FONTCONFIG_FILE / XKB / etc.
  runScript = "${wechat-unwrapped}/bin/wechat-unwrapped";

  # Expose the unwrapped derivation for debugging / inspection.
  passthru.unwrapped = wechat-unwrapped;

  # Make wechat-unwrapped's share dir visible inside the FHS namespace
  # (icons, desktop entry, fonts, etc.). Without this, the launcher can
  # still find everything via $out/share/wechat, but desktop entries in
  # the host's menu would not resolve.
  extraInstallCommands = ''
    # Symlink the desktop entry + icons into the FHS derivation's $out
    # so `nix profile install` registers them in the host menu.
    mkdir -p $out/share/applications
    mkdir -p $out/share/icons/hicolor
    ln -sf ${wechat-unwrapped}/share/applications/wechat.desktop \
          $out/share/applications/wechat.desktop
    # Recursively symlink icon themes
    for size_dir in ${wechat-unwrapped}/share/icons/hicolor/*; do
      size=$(basename "$size_dir")
      mkdir -p "$out/share/icons/hicolor/$size"
      ln -sf "$size_dir/apps" "$out/share/icons/hicolor/$size/apps" 2>/dev/null || true
    done

    # Also drop a tiny wrapper at $out/bin/wechat that calls the FHS launcher.
    # `buildFHSEnv` already installs its own wrapper at $out/bin/<pname>,
    # so this is just a convenience alias.
    if [ ! -e "$out/bin/wechat" ]; then
      ln -s wechat $out/bin/wechat 2>/dev/null || true
    fi
  '';

  meta = with pkgs.lib; {
    homepage = "https://linux.weixin.qq.com/";
    description = "Tencent WeChat desktop client (Linux)";
    longDescription = ''
      WeChat for Linux, repackaged from Tencent's official .deb.

      Two-layer build:
        1. `wechat-unwrapped` — unpacks the .deb, runs `autoPatchelfHook`
           over every ELF, and installs a wrapper that sets up
           `LD_LIBRARY_PATH`, `FONTCONFIG_FILE`, etc.
        2. `wechat` (this derivation) — wraps the unwrapped binary in an
           FHS namespace via `buildFHSEnv` so that absolute paths like
           `/usr/bin/lsblk`, `/usr/bin/udevadm`, `/usr/bin/ps` etc.
           (which WeChat pops at runtime) actually resolve.

      See https://linux.weixin.qq.com/ for upstream release info.
    '';
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    license = licenses.unfree;
    mainProgram = "wechat";
    maintainers = with maintainers; [ redskaber ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
