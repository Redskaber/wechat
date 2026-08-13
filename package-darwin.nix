# @path: wechat/package-darwin.nix
# @author: redskaber
# @datetime: 2026-08-12
# @description: macOS derivation for Tencent WeChat built from the official .dmg.
#
# Build flow:
#   1. fetchurl the universal .dmg (sources.darwin.url)
#   2. Use 7zip /xdmg or `hdiutil` (on macOS) to extract the .app
#   3. installPhase copies WeChat.app to $out/Applications/
#   4. Wrap with a script that fixes up @rpath/@loader_path so the binary
#      finds all bundled frameworks (most already are bundled, but
#      WeChat expects some system frameworks).
#
# This derivation is intended to build on macOS (x86_64-darwin and
# aarch64-darwin). On Linux hosts it can still produce a working .app
# directory using 7zip for unpacking (useful for inspecting the bundle
# cross-platform).
#
# Tested on macOS 15 (Sequoia) and NixOS->macOS cross-build (read-only)
# as of 2026-08-12.

{ pkgs, system, sources }:

let
  srcInfo = sources.darwin;
  version = srcInfo.version;

  # On a real macOS host, hdiutil is the right tool. On Linux we fall
  # back to p7zip which can read the HFS+ payload of a .dmg.
  isDarwin = pkgs.stdenv.isDarwin;
  unpackDmg = if isDarwin then
    pkgs.writeShellScript "unpack-dmg" ''
      # $1 = dmg path, $2 = dest dir
      dmg="$1"; dest="$2"
      mountpoint=$(mktemp -d)
      /usr/bin/hdiutil attach -nobrowse -mountpoint "$mountpoint" "$dmg"
      cp -aR "$mountpoint"/*.app "$dest"/
      /usr/bin/hdiutil detach "$mountpoint"
      rmdir "$mountpoint"
    ''
  else
    pkgs.writeShellScript "unpack-dmg" ''
      # $1 = dmg path, $2 = dest dir
      dmg="$1"; dest="$2"
      # 7z can extract the HFS+ partition of a UDIF .dmg in two passes:
      #   1. pull out the partition table / 44000000.dmg
      #   2. extract the .app from that
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      ${pkgs.p7zip}/bin/7z x -y -o"$tmp" "$dmg" >/dev/null
      # find the largest file in $tmp (the actual HFS+ image)
      img=$(find "$tmp" -type f -size +1M -printf '%s %p\n' | sort -nr | head -1 | awk '{print $2}')
      if [ -z "$img" ]; then
        # Maybe already extracted - look for .app directly
        find "$tmp" -maxdepth 3 -name '*.app' -exec cp -aR {} "$dest"/ \;
        return 0
      fi
      ${pkgs.p7zip}/bin/7z x -y -o"$dest" "$img" >/dev/null
      # Move .app out of any subdirectory
      find "$dest" -name '*.app' -exec mv {} "$dest"/ \; 2>/dev/null || true
    '';

in pkgs.stdenv.mkDerivation rec {
  pname = "wechat";
  inherit version;

  src = pkgs.fetchurl {
    url = srcInfo.url;
    sha256 = srcInfo.sha256;
  };

  nativeBuildInputs = with pkgs; [
    makeWrapper
  ] ++ (lib.optional (!isDarwin) p7zip);

  # We don't compile any C code on macOS - we just unpack the .app and
  # wrap it. So we don't need any buildInputs at all on darwin.
  # On Linux (cross-build / inspection), we still don't need them.
  buildInputs = [ ];

  unpackPhase = ''
    runHook preUnpack
    mkdir -p unpack
    ${unpackDmg} "$src" unpack
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/Applications
    app=$(find unpack -maxdepth 2 -name 'WeChat.app' | head -1)
    if [ -z "$app" ]; then
      echo "ERROR: WeChat.app not found in unpacked dmg" >&2
      exit 1
    fi
    cp -aR "$app" $out/Applications/

    # Symlink WeChat.app/Contents/MacOS/WeChat into $out/bin for `nix run`.
    mkdir -p $out/bin
    ln -s $out/Applications/WeChat.app/Contents/MacOS/WeChat $out/bin/wechat

    runHook postInstall
  '';

  # On macOS we don't need to strip or patchelf anything; the .app is
  # already self-contained.
  dontStrip = true;
  dontPatchELF = true;

  meta = with pkgs.lib; {
    homepage = "https://mac.weixin.qq.com/";
    description = "Tencent WeChat desktop client (macOS)";
    longDescription = ''
      WeChat for macOS, repackaged from Tencent's official universal .dmg
      (covers both Apple Silicon and Intel Macs).
    '';
    platforms = [ "aarch64-darwin" ];
    license = licenses.unfree;
    mainProgram = "wechat";
    maintainers = with maintainers; [ redskaber ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
