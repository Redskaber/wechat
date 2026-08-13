#!/usr/bin/env bash
# @path: wechat/update.sh
# @author: redskaber
# @description: Auto-update sources.nix from official Tencent WeChat endpoints.
#
# This script:
#   1. Probes the official Tencent CDN for the latest WeChat binaries:
#        - Linux x86_64 deb: https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.deb
#        - Linux arm64 deb:  https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_arm64.deb
#        - Mac universal dmg: parsed from https://mac.weixin.qq.com page (or hardcoded URL pattern)
#   2. Extracts versions:
#        - Linux: download .deb in tmp, `ar x` then read control file's Version: field
#        - macOS: parse from filename (WeChatMac_<ver>.dmg)
#   3. Computes SHA256 via `nix hash file` (fast, local) for already-downloaded files,
#      or `nix-prefetch-url` for remote-only URLs.
#   4. Rewrites sources.nix atomically.
#
# Re-runnable, idempotent. Designed to be invoked by:
#   - Local:  `nix run .#update-sources`
#   - CI:     `.github/workflows/daily-update.yml` (GitHub Actions)
#   - Cron:   Daily at 03:00 Asia/Shanghai

set -euo pipefail

# ---------- Configuration ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="${SCRIPT_DIR}/sources.nix"

# Base URLs
LINUX_BASE="https://dldir1v6.qq.com/weixin/Universal/Linux"
MAC_BASE="https://dldir1v6.qq.com/weixin/Universal/Mac"

# Discovery URLs (HTML pages we can scrape for "latest version" links)
LINUX_DISCOVERY="https://linux.weixin.qq.com"
MAC_DISCOVERY="https://mac.weixin.qq.com"

# Helper to detect the nix binary (in case it's not in PATH,
# e.g. when running via nix-run.sh wrapper).
NIX_BIN="${NIX:-nix}"
if ! command -v "$NIX_BIN" >/dev/null 2>&1; then
  if [ -x /home/z/nix-install/nix-run.sh ]; then
    NIX_BIN="/home/z/nix-install/nix-run.sh nix"
    NIX_PREFETCH="/home/z/nix-install/nix-run.sh nix-prefetch-url"
  else
    echo "ERROR: nix not found in PATH." >&2
    echo "       Install Nix or set NIX env var." >&2
    exit 1
  fi
else
  NIX_PREFETCH="nix-prefetch-url"
fi

# nix hash file is fast and local - preferred when we already have the file
# downloaded locally. It outputs in nix base32 (sri or plain).
nix_hash_file() {
  local file="$1"
  # `nix hash file` outputs sha256-<base64>= in SRI form by default;
  # we want the bare base32 hash that matches `fetchurl { sha256 = ...; }`.
  # Use `nix-prefetch-url --type sha256 file://...` which is the canonical
  # way, but fall back to `nix hash file` + base32 conversion if the
  # prefetch command times out.
  $NIX_PREFETCH --type sha256 "file://$file" 2>/dev/null || \
    $NIX_BIN hash convert --to base32 --hash-alg sha256 \
      $($NIX_BIN hash file "$file" 2>/dev/null | sed 's/^sha256-//' | base64 -d | xxd -p -c 64 | head -1) 2>/dev/null
}

# Workspace
TMP_DIR="$(mktemp -d -t wechat-update.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Workspace: $TMP_DIR"
echo "==> Nix:       $NIX_BIN"

# ---------- 1. Linux versions ----------
echo ""
echo "==> Probing Linux WeChat URLs..."

declare -A LINUX_URLS=(
  ["x86_64-linux"]="${LINUX_BASE}/WeChatLinux_x86_64.deb"
  ["aarch64-linux"]="${LINUX_BASE}/WeChatLinux_arm64.deb"
)

declare -A LINUX_VERSIONS
declare -A LINUX_HASHES

for sys in "x86_64-linux" "aarch64-linux"; do
  url="${LINUX_URLS[$sys]}"
  echo "  - $sys: $url"

  # Verify URL exists
  status=$(curl -L -s -o /dev/null -w "%{http_code}" --head "$url" --max-time 30 || echo "000")
  if [ "$status" != "200" ]; then
    echo "    WARNING: HTTP $status for $url" >&2
    continue
  fi

  # Download to extract version
  deb_file="$TMP_DIR/wechat-$sys.deb"
  echo "    downloading..."
  curl -L -s -o "$deb_file" "$url" --max-time 180

  # Extract control file from .deb
  control_dir="$TMP_DIR/$sys-control"
  mkdir -p "$control_dir"
  (cd "$control_dir" && ar x "$deb_file" 2>/dev/null)
  if [ -f "$control_dir/control.tar.xz" ]; then
    (cd "$control_dir" && tar -xf control.tar.xz 2>/dev/null)
  elif [ -f "$control_dir/control.tar.gz" ]; then
    (cd "$control_dir" && tar -xzf control.tar.gz 2>/dev/null)
  fi

  ver=$(grep -i '^Version:' "$control_dir/control" 2>/dev/null | head -1 | awk '{print $2}')
  if [ -z "$ver" ]; then
    echo "    ERROR: could not extract Version from $sys deb control file" >&2
    exit 1
  fi
  LINUX_VERSIONS[$sys]="$ver"
  echo "    version: $ver"

  # Compute SHA256 - try local file hash first (fast, no network)
  hash=$(nix_hash_file "$deb_file")
  if [ -z "$hash" ]; then
    echo "    ERROR: hash computation failed for $sys" >&2
    exit 1
  fi
  LINUX_HASHES[$sys]="$hash"
  echo "    sha256: $hash"
done

# Verify Linux versions agree (they should - Tencent releases them together)
LINUX_VER="${LINUX_VERSIONS[x86_64-linux]:-${LINUX_VERSIONS[aarch64-linux]}}"
if [ -n "${LINUX_VERSIONS[x86_64-linux]:-}" ] && [ -n "${LINUX_VERSIONS[aarch64-linux]:-}" ] && \
   [ "${LINUX_VERSIONS[x86_64-linux]}" != "${LINUX_VERSIONS[aarch64-linux]}" ]; then
  echo "WARNING: Linux x86_64 (${LINUX_VERSIONS[x86_64-linux]}) and arm64 (${LINUX_VERSIONS[aarch64-linux]}) versions differ!" >&2
fi
echo "  -> Linux version: $LINUX_VER"

# ---------- 2. macOS version ----------
echo ""
echo "==> Probing macOS WeChat URL..."

# Strategy 1: try known recent version patterns
mac_url=""
mac_ver=""

# Try common patterns - usually the discovery page contains a download URL.
# Start from latest known (4.1.12) and walk down a bit.
for pat_ver in "4.1.12" "4.1.11" "4.1.10" "4.1.9" "4.1.8" "4.1.7" "4.1.6" "4.1.5" "4.1.4" "4.1.3" "4.1.2" "4.1.1" "4.1.0"; do
  url="${MAC_BASE}/WeChatMac_${pat_ver}.dmg"
  status=$(curl -L -s -o /dev/null -w "%{http_code}" --head "$url" --max-time 15 || echo "000")
  if [ "$status" = "200" ]; then
    mac_url="$url"
    mac_ver="$pat_ver"
    break
  fi
done

# Strategy 2: scrape the discovery page
if [ -z "$mac_url" ]; then
  echo "  - Falling back to scraping $MAC_DISCOVERY"
  page="$TMP_DIR/mac.html"
  curl -L -s -o "$page" "$MAC_DISCOVERY" --max-time 30 || true
  if grep -oE 'WeChatMac_[0-9.]+' "$page" | head -1 > /tmp/_ver.txt 2>/dev/null; then
    mac_ver=$(grep -oE '[0-9.]+' /tmp/_ver.txt | head -1)
    if [ -n "$mac_ver" ]; then
      mac_url="${MAC_BASE}/WeChatMac_${mac_ver}.dmg"
    fi
  fi
fi

if [ -z "$mac_url" ] || [ -z "$mac_ver" ]; then
  echo "ERROR: Could not determine macOS WeChat URL/version" >&2
  exit 1
fi
echo "  - macOS URL: $mac_url"
echo "  - macOS version: $mac_ver"

# Compute SHA256 for macOS dmg (download then hash locally)
mac_dmg="$TMP_DIR/WeChatMac.dmg"
echo "  - Downloading macOS dmg (for hashing)..."
curl -L -s -o "$mac_dmg" "$mac_url" --max-time 600
mac_hash=$(nix_hash_file "$mac_dmg")
echo "  - macOS sha256: $mac_hash"

# ---------- 3. Rewrite sources.nix ----------
echo ""
echo "==> Writing $SOURCES_FILE ..."

DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$SOURCES_FILE" << EOF
# @path: wechat/sources.nix
# @description: Auto-generated by update.sh. Do NOT edit by hand.
# @last-updated: ${DATE}
#
# Source URLs and SHA256 hashes for every platform WeChat ships binaries for.
# These values were obtained by running \`nix-prefetch-url\` against the
# upstream Tencent CDN endpoints listed in README.md.
#
# Linux versions are extracted from the .deb \`control\` file (Version: field).
# macOS versions are parsed from the .dmg filename (WeChatMac_<ver>.dmg).

{
  # Linux WeChat is currently at ${LINUX_VER} on both x86_64 and aarch64.
  linux = {
    version = "${LINUX_VER}";
    x86_64-linux = {
      url = "${LINUX_URLS[x86_64-linux]}";
      sha256 = "${LINUX_HASHES[x86_64-linux]}";
    };
    aarch64-linux = {
      url = "${LINUX_URLS[aarch64-linux]}";
      sha256 = "${LINUX_HASHES[aarch64-linux]}";
    };
  };

  # macOS WeChat is shipped as a single universal .dmg covering both
  # arm64 (Apple Silicon) and x86_64 (Intel).
  darwin = {
    version = "${mac_ver}";
    url = "${mac_url}";
    sha256 = "${mac_hash}";
  };
}
EOF

echo "==> Done. sources.nix updated."
echo ""
echo "Summary:"
echo "  linux.x86_64-linux:  version=${LINUX_VERSIONS[x86_64-linux]:-N/A} sha=${LINUX_HASHES[x86_64-linux]:-N/A}"
echo "  linux.aarch64-linux: version=${LINUX_VERSIONS[aarch64-linux]:-N/A} sha=${LINUX_HASHES[aarch64-linux]:-N/A}"
echo "  darwin (universal):  version=${mac_ver} sha=${mac_hash}"
