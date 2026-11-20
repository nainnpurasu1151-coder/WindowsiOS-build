#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build a synthetic ESD whose image layout mirrors the Microsoft retail
# Windows 11 ARM64 ESD that scripts/provision_windows_arm64.py and
# scripts/optimize_windows_lite.py were written against:
#
#   index 1: setup media files (the tree /efi, /boot, /bootmgr.efi lives in)
#   index 2: Microsoft Windows PE (becomes boot.wim's image 1 after export)
#   index 3-5: filler (never referenced; duplicates of index 1, and WIM
#              file-resource dedup keeps them nearly free)
#   index 6: Windows 11 Pro edition image (exported alone -> install.wim,
#              then applied by DISM as /Index:1)
#
# Because the layout is constructed here, it does NOT depend on the source
# media's own index numbering -- which is what makes non-en-US media (e.g.
# a ja-JP UUP set) usable without touching the provisioning scripts.
#
# Usage: build_synthetic_esd.sh <source.iso> <output.esd>
# Requires: wimlib-imagex, hdiutil (macOS).
set -euo pipefail
trap 'echo "::error::build_synthetic_esd.sh failed at line $LINENO: ${BASH_COMMAND:0:300}" >&2' ERR

ISO="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$2"
mkdir -p "$(dirname "$OUT")"
WIMLIB="${WIMLIB:-/opt/homebrew/bin/wimlib-imagex}"
[ -x "$WIMLIB" ] || WIMLIB="$(command -v wimlib-imagex)"

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
mkdir -p "$MNT"
cleanup() {
    hdiutil detach "$MNT" >/dev/null 2>&1 || true
    # The stage tree is copied from the read-only ISO mount, so its
    # directories keep r-x modes; a plain rm -rf by the (non-root) runner
    # user then fails with Permission denied on every file inside them
    # (seen in image workflow run #6, where the rm spam buried the real
    # error). Make everything writable first so cleanup actually cleans.
    chmod -R u+w "$TMP" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "== Attaching $ISO =="
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$ISO" >/dev/null
ls "$MNT"

# --- Locate boot.wim / install image inside the ISO ---------------------
BOOT_WIM="$(find "$MNT" -iname boot.wim | head -1)"
INSTALL_IMG="$(find "$MNT" -iname install.wim -o -iname install.esd | head -1)"
[ -n "$BOOT_WIM" ] && [ -n "$INSTALL_IMG" ] || { echo "::error::boot.wim/install image not found in ISO"; exit 1; }
cp "$BOOT_WIM" "$TMP/boot.wim"
cp "$INSTALL_IMG" "$TMP/install.img"

# Index of the WinPE image inside boot.wim (name "Microsoft Windows PE",
# as opposed to "Microsoft Windows Setup").
PE_IDX="$(python3 - "$TMP/boot.wim" "$WIMLIB" <<'PYEOF'
import subprocess, sys
out = subprocess.check_output([sys.argv[2], "info", sys.argv[1]], text=True)
blocks = out.split("Index:")
for b in blocks[1:]:
    idx = b.strip().splitlines()[0].strip()
    name = ""
    for line in b.splitlines():
        if line.strip().startswith("Name:"):
            name = line.split(":", 1)[1].strip()
            break
    if "Windows PE" in name:
        sys.stdout.write(idx)
        break
else:
    sys.stdout.write("1")
PYEOF
)"
# Index of the Pro (not Pro N / Pro for Workstations) image.
PRO_IDX="$(python3 - "$TMP/install.img" "$WIMLIB" <<'PYEOF'
import subprocess, sys
out = subprocess.check_output([sys.argv[2], "info", sys.argv[1]], text=True)
blocks = out.split("Index:")
cands = []
for b in blocks[1:]:
    idx = b.strip().splitlines()[0].strip()
    name = ""
    for line in b.splitlines():
        if line.strip().startswith("Name:"):
            name = line.split(":", 1)[1].strip()
            break
    cands.append((idx, name))
for idx, name in cands:
    if name == "Windows 11 Pro":
        sys.stdout.write(idx)
        break
else:
    for idx, name in cands:
        if "Pro" in name and " N" not in name and "Workstation" not in name:
            sys.stdout.write(idx)
            break
    else:
        sys.exit(f"no Pro image found in install image: {cands}")
PYEOF
)"
echo "WinPE index: $PE_IDX / Pro index: $PRO_IDX"

# --- Stage the setup-media files (ISO root: efi/, boot/, bootmgr.efi) ---
STAGE="$TMP/stage"
mkdir -p "$STAGE"
for item in efi boot bootmgr.efi; do
    src="$(find "$MNT" -maxdepth 2 -iname "$item" | head -1)"
    [ -n "$src" ] || { echo "::error::ISO root is missing $item"; exit 1; }
    if [ -d "$src" ]; then
        cp -R "$src" "$STAGE/"
    else
        cp "$src" "$STAGE/"
    fi
done

# --- Assemble the synthetic ESD (solid/LZMS, like a retail ESD) --------
# Only the FIRST image may be created with `capture`: wimlib's capture
# OVERWRITES an existing destination file (it is the create primitive);
# the appending primitives are `export` and `append`. An earlier version
# used `capture` for the three filler images too, so each filler silently
# replaced the whole ESD and the final file held only {last filler, Pro}
# = 2 images -- the "synthetic ESD has 2 images, expected 6" failure of
# image workflow run #6 (reproduced locally with wimlib 1.14.4).
rm -f "$OUT"
"$WIMLIB" capture "$STAGE" "$OUT" "Windows Setup Media" --solid >/dev/null
"$WIMLIB" export "$TMP/boot.wim" "$PE_IDX" "$OUT" --solid >/dev/null
for i in 3 4 5; do
    "$WIMLIB" append "$STAGE" "$OUT" "Windows Setup Media (layout filler $i)" --solid >/dev/null
done
"$WIMLIB" export "$TMP/install.img" "$PRO_IDX" "$OUT" --solid >/dev/null

echo "== Synthetic ESD layout =="
"$WIMLIB" info "$OUT" | grep -E "Index:|Name:" || true
COUNT="$("$WIMLIB" info "$OUT" | grep -c '^Index:' || true)"
[ "$COUNT" = "6" ] || { echo "::error::synthetic ESD has $COUNT images, expected 6"; exit 1; }
NAMES="$("$WIMLIB" info "$OUT" | grep '^Name:' | sed 's/^Name:[[:space:]]*//' | paste -sd '|' -)"
echo "::notice::synthetic ESD layout (6 images): $NAMES"
ls -lh "$OUT"
echo "=== synthetic ESD ready ==="
