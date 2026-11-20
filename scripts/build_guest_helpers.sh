#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the freestanding AArch64 Win32 guest helpers:
#   build/opt_hive_arm64.exe   (tools/opt_hive_arm64.c, console, entry mainCRTStartup)
#   build/WinIOSBrowser.exe    (tools/winios_browser_arm64.c, GUI, entry WinMainCRTStartup)
#
# The upstream repo ships the sources but no build rule (README only says
# "llvm/lld"). Both sources are fully freestanding: they declare their own
# Win32 imports and never call libc (no memcpy/memset/strlen), so all they
# need is clang + lld plus import libraries, which llvm-dlltool generates
# from the .def files in tools/win32/.
#
# Requires Homebrew clang + llvm-dlltool (the llvm formula) and an lld
# linker (ld.lld / lld-link, from the SEPARATE lld formula -- the llvm
# formula does not ship one). If lld is missing and brew is available,
# the script installs the lld formula itself, because the CI
# guest-helpers job installs llvm only:
#   brew install llvm lld
set -euo pipefail

# Surface the failing command as a workflow annotation, so a CI failure is
# diagnosable from the run page / public API without the raw job log.
trap 'cmd="${BASH_COMMAND//\%/%25}"; echo "::error::build_guest_helpers.sh failed at line $LINENO: ${cmd:0:300}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT/win32"

# Homebrew LLVM is keg-only: its binaries never land on PATH, so resolve the
# prefix explicitly (default path, then `brew --prefix llvm`, then PATH).
LLVM_BIN="${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}"
if [ ! -x "$LLVM_BIN/llvm-dlltool" ] && command -v brew >/dev/null 2>&1; then
    BREW_LLVM="$(brew --prefix llvm 2>/dev/null || true)"
    [ -n "$BREW_LLVM" ] && [ -x "$BREW_LLVM/bin/llvm-dlltool" ] && LLVM_BIN="$BREW_LLVM/bin"
fi
CLANG="${CLANG:-$LLVM_BIN/clang}"
DLLTOOL="${DLLTOOL:-$LLVM_BIN/llvm-dlltool}"
[ -x "$CLANG" ] || CLANG="$(command -v clang || true)"
[ -x "$DLLTOOL" ] || DLLTOOL="$(command -v llvm-dlltool || true)"
if [ -z "${CLANG:-}" ] || [ ! -x "$CLANG" ] || [ -z "${DLLTOOL:-}" ] || [ ! -x "$DLLTOOL" ]; then
    echo "::error::LLVM tools not found (clang='${CLANG:-none}', llvm-dlltool='${DLLTOOL:-none}'). Is 'brew install llvm' done?"
    exit 1
fi
echo "clang:   $CLANG"
echo "dlltool: $DLLTOOL"
# Version banners are diagnostics ONLY and must never abort the build.
# CI run #2 died on the clang line via `| head -1` and run #3 died on the
# dlltool line via `| sed -n '1p'`: under `set -o pipefail`, a banner
# pipeline whose reader stops after line 1 leaves the version printer to
# die with SIGPIPE (141), and pipefail promotes that to a script failure.
# (The ERR annotation names the pipeline's last command either way, so it
# cannot distinguish "sed stopped reading" from "the tool itself failed" --
# and for a banner, the distinction does not matter.) Capture the output
# instead: no pipe, no SIGPIPE, and failures are swallowed on purpose.
# Tool *presence* is enforced by the -x checks above, and the real build
# steps below (dlltool .def processing, clang+lld links) stay strict.
CLANG_BANNER="$("$CLANG" --version 2>/dev/null || true)"
DLLTOOL_BANNER="$("$DLLTOOL" --version 2>/dev/null || true)"
echo "clang version:   ${CLANG_BANNER%%$'\n'*}"
echo "dlltool version: ${DLLTOOL_BANNER%%$'\n'*}"
# clang -fuse-ld=lld needs an lld linker (ld.lld / lld-link). Homebrew's
# llvm formula does NOT ship one -- lld is a separate formula -- and the
# CI guest-helpers job installs llvm only, which is exactly how run #4
# died at the first link step (the previous version only warned about
# the missing linker, then clang failed with nothing to run). Resolve
# it robustly instead of just warning: next to clang, then the lld
# formula's prefix, then PATH; if
# still missing and brew is available, install the lld formula and
# resolve again. The resolved bin dir is prepended to PATH, which is
# where clang's -fuse-ld=lld search falls back to.
LLD_PREFIX=""
if command -v brew >/dev/null 2>&1; then
    LLD_PREFIX="$(brew --prefix lld 2>/dev/null || true)"
fi
find_lld_bin() {
    local d p
    for d in "$(dirname "$CLANG")" "${LLD_PREFIX:-}/bin" \
             /opt/homebrew/opt/lld/bin /usr/local/opt/lld/bin; do
        [ -n "$d" ] && [ "$d" != "/bin" ] || continue
        if [ -x "$d/ld.lld" ] || [ -x "$d/lld-link" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    p="$(command -v ld.lld || command -v lld-link || true)"
    if [ -n "$p" ]; then
        dirname "$p"
        return 0
    fi
    return 1
}
LLD_BIN="$(find_lld_bin || true)"
if [ -z "$LLD_BIN" ] && command -v brew >/dev/null 2>&1; then
    echo "lld linker not found; installing the Homebrew lld formula..."
    brew install lld || true
    LLD_PREFIX="$(brew --prefix lld 2>/dev/null || true)"
    LLD_BIN="$(find_lld_bin || true)"
fi
if [ -z "$LLD_BIN" ]; then
    echo "::error::lld linker (ld.lld / lld-link) not found and 'brew install lld' did not provide one; -fuse-ld=lld cannot work without it."
    exit 1
fi
export PATH="$LLD_BIN:$PATH"
LLD_LINK="$LLD_BIN/lld-link"
[ -x "$LLD_LINK" ] || LLD_LINK="$LLD_BIN/ld.lld"
LLD_BANNER="$("$LLD_LINK" --version 2>/dev/null || true)"
echo "lld:     $LLD_LINK"
echo "lld version:     ${LLD_BANNER%%$'\n'*}"

# 1. Import libraries from the .def files (function lists mirror the
#    __declspec(dllimport) declarations in the sources).
for dll in kernel32 advapi32 ws2_32; do
    "$DLLTOOL" -m arm64 -d "$ROOT/tools/win32/$dll.def" -l "$OUT/win32/$dll.lib"
done
ls -lh "$OUT/win32/"

CFLAGS=(--target=aarch64-pc-windows-msvc -O2 -ffreestanding -nostdlib
        -fno-stack-protector -fuse-ld=lld -Wno-unused-parameter)

# Run one link step with output captured. On failure, mirror the tail of
# the linker output as ::error:: annotations (one per line, %-escaped):
# the ERR trap alone only surfaces the command line, and the raw job log
# needs auth, so without this the actual linker error stays invisible
# from the run page / public API.
link_step() {
    local log line
    log="$(mktemp)"
    if "$@" >"$log" 2>&1; then
        cat "$log"
        rm -f "$log"
        return 0
    fi
    cat "$log" >&2
    tail -n 12 "$log" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        line="${line//\%/%25}"
        echo "::error::linker: ${line:0:280}"
    done
    rm -f "$log"
    return 1
}

# 2. opt_hive_arm64.exe: console subsystem, kernel32 + advapi32.
link_step "$CLANG" "${CFLAGS[@]}" \
    -Wl,-entry:mainCRTStartup -Wl,-subsystem:console \
    "$ROOT/tools/opt_hive_arm64.c" \
    "$OUT/win32/kernel32.lib" "$OUT/win32/advapi32.lib" \
    -o "$OUT/opt_hive_arm64.exe"

# 3. WinIOSBrowser.exe: windows subsystem, kernel32 + ws2_32.
link_step "$CLANG" "${CFLAGS[@]}" \
    -Wl,-entry:WinMainCRTStartup -Wl,-subsystem:windows \
    "$ROOT/tools/winios_browser_arm64.c" \
    "$OUT/win32/kernel32.lib" "$OUT/win32/ws2_32.lib" \
    -o "$OUT/WinIOSBrowser.exe"

ls -lh "$OUT/opt_hive_arm64.exe" "$OUT/WinIOSBrowser.exe"
echo "=== guest helpers built ==="
