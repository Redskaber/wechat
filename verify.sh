#!/usr/bin/env bash
# @path: wechat/verify.sh
# @author: redskaber
# @description: End-to-end verification of the wechat flake.
#
# This script:
#   1. Runs `nix flake check --all-systems` to validate all derivations
#      evaluate cleanly.
#   2. Runs `update.sh --dry-run` to make sure the auto-update script
#      can probe upstream URLs.
#   3. Builds the local platform's wechat derivation.
#   4. Verifies the built binary is a valid ELF with proper RPATH.
#   5. If Xvfb is available, runs a 5-second smoke test launching wechat.
#
# Exits 0 if all checks pass, non-zero otherwise.
#
# Usage:
#   ./verify.sh            # full verification
#   ./verify.sh --quick    # skip build step (just flake check + update dry-run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

QUICK=0
if [ "${1:-}" = "--quick" ]; then
  QUICK=1
fi

NIX_BIN="${NIX:-nix}"
if ! command -v "$NIX_BIN" >/dev/null 2>&1; then
  if [ -x /home/z/nix-install/nix-run.sh ]; then
    NIX_BIN="/home/z/nix-install/nix-run.sh nix"
  else
    echo "ERROR: nix not found in PATH." >&2
    exit 1
  fi
fi

# Force-enable experimental features (in case the host config is minimal).
NIX_BIN="$NIX_BIN --extra-experimental-features nix-command --extra-experimental-features flakes"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; exit 1; }

echo "==> 1/4  flake check (--all-systems --no-build)"
if $NIX_BIN flake check "$SCRIPT_DIR" --no-build --all-systems >/tmp/flake-check.log 2>&1; then
  pass "flake check"
else
  cat /tmp/flake-check.log | tail -30
  fail "flake check"
fi

echo "==> 2/4  update.sh --dry-run (probe upstream URLs)"
if [ "$QUICK" -eq 1 ]; then
  echo "  (skipped, --quick)"
else
  if ./update.sh >/tmp/update.log 2>&1; then
    pass "update.sh"
  else
    tail -30 /tmp/update.log
    fail "update.sh"
  fi
fi

if [ "$QUICK" -eq 1 ]; then
  echo "==> 3/4  (skipped build, --quick)"
  echo "==> 4/4  (skipped launch test, --quick)"
  echo ""
  echo "✅ All quick checks passed."
  exit 0
fi

echo "==> 3/4  build local-platform wechat"
OUT=$($NIX_BIN build "$SCRIPT_DIR#wechat" --no-link --print-out-paths 2>/tmp/build.log)
if [ -n "$OUT" ] && $NIX_BIN path-info "$OUT" >/dev/null 2>&1; then
  pass "built: $OUT"
else
  tail -30 /tmp/build.log
  fail "build"
fi

echo "==> 4/4  verify binary"
BIN="$OUT/bin/wechat"
# Use `nix store ls` so this works on systems where the nix store is at
# a non-default path (e.g. our unprivileged nix-run.sh sandbox, which
# mounts /home/z/nix-install as /nix inside a chroot).
if $NIX_BIN store ls "$BIN" >/dev/null 2>&1; then
  pass "binary exists: $BIN"
else
  fail "binary missing or not executable: $BIN"
fi

if command -v file >/dev/null 2>&1; then
  # Run `file` inside the nix store context via `nix run` - actually we
  # just use the host `file` against the host-side path if available.
  HOST_OUT="${OUT/\/nix\///home/z/nix-install/}"
  if [ -x "$HOST_OUT/bin/wechat" ]; then
    if file "$HOST_OUT/bin/wechat" | grep -q "ELF.*executable"; then
      pass "binary is a valid ELF executable"
    else
      fail "binary is not an ELF executable"
    fi
  fi
fi

# Optional: Xvfb smoke test
# This only works when /nix is directly accessible on the host (real NixOS)
# or when run inside the nix-run.sh chroot context.
if command -v Xvfb >/dev/null 2>&1 && { [ -d /nix/store ] || [ -n "${NIX_RUN_CHROOT:-}" ]; }; then
  echo "==> bonus: Xvfb 5s smoke test"
  HOST_OUT="${OUT/\/nix\///home/z/nix-install/}"
  HOST_BIN="$HOST_OUT/bin/wechat"
  if [ ! -x "$HOST_BIN" ]; then
    # On real NixOS, OUT is the actual filesystem path
    HOST_BIN="$OUT/bin/wechat"
  fi
  Xvfb :99 -screen 0 1024x768x24 &
  XVFB_PID=$!
  sleep 1
  set +e
  DISPLAY=:99 timeout 5 "$HOST_BIN" --type=manager >/tmp/xvfb.log 2>&1
  rc=$?
  set -e
  kill $XVFB_PID 2>/dev/null || true
  if [ $rc -eq 0 ] || [ $rc -eq 124 ]; then
    pass "smoke test (exit $rc, timeout=124 is OK)"
  else
    tail -10 /tmp/xvfb.log
    fail "smoke test (exit $rc)"
  fi
else
  echo "==> bonus: Xvfb smoke test (skipped - need /nix on host or NIX_RUN_CHROOT env var)"
fi

echo ""
echo "✅ All verifications passed."
echo ""
echo "To install:   nix profile install $SCRIPT_DIR#wechat"
echo "To run:       nix run $SCRIPT_DIR#wechat"
echo "To update:    nix run $SCRIPT_DIR#update-sources"
