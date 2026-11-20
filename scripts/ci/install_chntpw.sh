#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build chntpw 140201 (Offline NT Password Editor) from pinned upstream
# source and install it as <prefix>/bin/chntpw.
#
# Why this exists: the official UUP dump converter (used by
# scripts/ci/fetch_uup_esd.sh) requires a `chntpw` binary to edit the
# SOFTWARE hive of the WinPE image it builds from winre.wim (it sets
# Microsoft\Windows NT\CurrentVersion\SystemRoot and ...\WinPE\InstRoot
# so the image behaves like retail setup media). Homebrew core no longer
# carries a chntpw formula at all, and the third-party tap the converter
# readme suggests (sidneys/homebrew) pins OpenSSL 1.0, which cannot
# build on current macOS. Building the pristine upstream source against
# Homebrew's openssl@3 works -- the registry-editor path the converter
# uses (`chntpw -e`) never exercises the legacy SAM crypto code that
# links OpenSSL. Verified locally: builds clean (incl. with
# -Werror=implicit-function-declaration), and the exact converter edit
# sequence (create keys, set REG_SZ values, write hive back, re-open)
# round-trips correctly.
#
# Usage: install_chntpw.sh [prefix]     (default: <repo>/work/tools)
set -euo pipefail
trap 'echo "::error::install_chntpw.sh failed at line $LINENO: ${BASH_COMMAND:0:300}" >&2' ERR

VERSION="140201"
SHA256="96e20905443e24cba2f21e51162df71dd993a1c02bfa12b1be2d0801a4ee2ccc"
URLS=(
    "https://distfiles.macports.org/chntpw/chntpw-source-${VERSION}.zip"
    "https://pogostick.net/~pnh/ntpasswd/chntpw-source-${VERSION}.zip"
)

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX="${1:-$ROOT/work/tools}"
DEST="$PREFIX/bin"
mkdir -p "$DEST"

if [ -x "$DEST/chntpw" ]; then
    echo "chntpw already built: $DEST/chntpw"
    exit 0
fi

# OpenSSL headers/lib (linked by libsam.o; brew step in the workflow
# normally pulls openssl@3 in as a dependency of qemu/wimlib/aria2, but
# do not rely on that).
OSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
if [ -z "$OSSL_PREFIX" ] || [ ! -f "$OSSL_PREFIX/include/openssl/des.h" ]; then
    echo "== Installing openssl@3 (chntpw build dependency) =="
    brew install openssl@3
    OSSL_PREFIX="$(brew --prefix openssl@3)"
fi
echo "Building chntpw ${VERSION} against OpenSSL at $OSSL_PREFIX"

TMP="$(mktemp -d)"
ZIP="$TMP/chntpw-source-${VERSION}.zip"
ok=""
for url in "${URLS[@]}"; do
    echo "== Downloading $url =="
    if curl -L --fail --retry 3 -o "$ZIP" "$url"; then ok=1; break; fi
done
[ -n "$ok" ] || { echo "::error::could not download chntpw source from any mirror"; exit 1; }

GOT="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
[ "$GOT" = "$SHA256" ] || { echo "::error::chntpw source SHA-256 mismatch: got $GOT, want $SHA256"; exit 1; }
echo "SHA-256 verified: $GOT"

if command -v unzip >/dev/null 2>&1; then
    unzip -q "$ZIP" -d "$TMP"
else
    ditto -x -k "$ZIP" "$TMP"
fi
SRC="$TMP/chntpw-${VERSION}"
[ -f "$SRC/chntpw.c" ] || { echo "::error::unexpected chntpw source layout under $TMP"; ls -la "$TMP"; exit 1; }

CC_BIN="$(command -v clang || command -v cc || command -v gcc)"
echo "== Compiling with $CC_BIN =="
# -fcommon: the 2014 codebase relies on pre-C99 tentative-definition
# merging; modern clang/gcc default to -fno-common and fail to link.
"$CC_BIN" -DUSEOPENSSL -O2 -fcommon -Wno-deprecated-declarations \
    -I"$SRC" -I"$OSSL_PREFIX/include" \
    -o "$DEST/chntpw" \
    "$SRC/chntpw.c" "$SRC/ntreg.c" "$SRC/edlib.c" "$SRC/libsam.c" \
    -L"$OSSL_PREFIX/lib" -lcrypto
chmod +x "$DEST/chntpw"

USAGE_OUT="$("$DEST/chntpw" 2>&1 || true)"
case "$USAGE_OUT" in
    *"chntpw version"*) : ;;
    *) echo "::error::built chntpw does not run"; printf '%s\n' "$USAGE_OUT" | head -5; exit 1 ;;
esac
rm -rf "$TMP"
echo "=== chntpw ready: $DEST/chntpw ==="
printf '%s\n' "$USAGE_OUT" | head -1
