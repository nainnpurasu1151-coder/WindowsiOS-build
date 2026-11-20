#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fetch Windows 11 ARM64 installation media for the provisioning scripts
# and place a retail-layout ESD at work/downloads/Win11_24H2_ARM64_en-us.esd
# (the exact path/name scripts/provision_windows_arm64.py and
# scripts/optimize_windows_lite.py hard-code).
#
# Two sources, in priority order:
#   1. ESD_URL set: download that ESD directly (escape hatch for a fresh
#      Microsoft software-download link, which is session/time limited).
#   2. UUP dump (default): resolve a Windows 11 ARM64 consumer build via
#      the public UUP dump JSON API (https://api.uupdump.net), download
#      the Professional UUP file set -- every file is served from
#      Microsoft's own update servers and verified against the SHA-1 the
#      API publishes -- convert it to an ISO with the official UUP dump
#      converter, and rebuild a retail-layout ESD from the ISO with
#      scripts/ci/build_synthetic_esd.sh.
#
# Environment:
#   ESD_URL     direct .esd URL (optional)
#   UUP_UUID    UUP update UUID (optional; default: newest match below)
#   UUP_SEARCH  listid search string (default: 26100)
#   UUP_LANG    language code for the UUP set (default: en-us)
#   UUP_EDITION edition for the UUP set (default: professional)
#
# Requires: curl, python3, aria2 (optional, curl fallback), git, wimlib,
# cabextract, plus genisoimage or mkisofs for the converter. chntpw (also
# a hard converter requirement) is built from pinned upstream source by
# scripts/ci/install_chntpw.sh, because Homebrew no longer carries it.
set -euo pipefail
trap 'echo "::error::fetch_uup_esd.sh failed at line $LINENO: ${BASH_COMMAND:0:300}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/work"
OUT_ESD="$WORK/downloads/Win11_24H2_ARM64_en-us.esd"
API="https://api.uupdump.net"
UUP_DIR="$WORK/uup"
mkdir -p "$WORK/downloads"

# --- begin run logging ---------------------------------------------------
# GitHub annotations only surface lines that contain workflow commands
# (::error:: / ::warning:: / ::notice::). A failure that emits none --
# e.g. a *parse* error under the macOS runner /bin/bash 3.2, where the
# ERR trap never gets a chance to run -- otherwise shows up as a bare
# "Process completed with exit code 2" with no explanation anywhere
# (exactly how image workflow run #4 died; see the WARNING in the UUID
# resolution heredoc below). So from here on, mirror all output to a
# log file, and on any non-zero exit re-emit the tail of that log as
# ::error:: annotations through the saved real stdout (fd 3).
FETCH_LOG="$WORK/fetch_uup_esd.log"
# Set to 1 only at the points where the script has genuinely finished
# its job (just before the ESD branch exit 0, and at the end of the UUP
# route). fetch_on_exit treats "status 0 but never completed" as a
# failure: under bash 3.2 with set -e, a parse error is reported to the
# EXIT trap as status 0, which would otherwise turn a dead script into
# a green step.
FETCH_COMPLETED=""
if command -v tee >/dev/null 2>&1; then
    : > "$FETCH_LOG"
    exec 3>&1
    exec > >(tee -a "$FETCH_LOG") 2>&1
    fetch_on_exit() {
        local rc=$?
        if [ "$rc" -eq 0 ] && [ -z "$FETCH_COMPLETED" ]; then
            rc=2
        fi
        if [ "$rc" -ne 0 ]; then
            # Close the tee feed, then wait for the log size to settle
            # so the tail below really is the tail.
            exec 1>&- 2>&-
            local prev="" cur="" tries=0
            while [ "$tries" -lt 10 ]; do
                cur="$(wc -c < "$FETCH_LOG" 2>/dev/null | tr -d ' ')"
                if [ -n "$prev" ] && [ "$cur" = "$prev" ]; then
                    break
                fi
                prev="$cur"
                tries=$((tries + 1))
                sleep 0.3
            done
            echo "::error::fetch_uup_esd.sh exited with code $rc; last log lines follow" >&3
            tail -n 15 "$FETCH_LOG" 2>/dev/null | while IFS= read -r logline; do
                printf '::error::%s\n' "$(printf '%s' "$logline" | sed -e 's/%/%25/g' -e 's/\r/%0D/g')" >&3
            done
        fi
        exit "$rc"
    }
else
    fetch_on_exit() {
        local rc=$?
        if [ "$rc" -eq 0 ] && [ -z "$FETCH_COMPLETED" ]; then
            rc=2
        fi
        if [ "$rc" -ne 0 ]; then
            echo "::error::fetch_uup_esd.sh exited with code $rc (tee unavailable; scroll the step log for the cause)"
        fi
        exit "$rc"
    }
fi
trap fetch_on_exit EXIT
echo "::notice::fetch_uup_esd.sh starting (bash $BASH_VERSION)"
# --- end run logging -----------------------------------------------------

if [ -n "${ESD_URL:-}" ]; then
    echo "== Downloading ESD directly from ESD_URL =="
    curl -L --fail --retry 5 --retry-all-errors --retry-delay 5 -o "$OUT_ESD" "$ESD_URL"
    ls -lh "$OUT_ESD"
    echo "=== ESD ready (direct URL) ==="
    FETCH_COMPLETED=1
    exit 0
fi

UUID="${UUP_UUID:-}"
SEARCH="${UUP_SEARCH:-26100}"
LANG_CODE="${UUP_LANG:-en-us}"
EDITION="${UUP_EDITION:-professional}"

# --- begin network helpers ---
# api.uupdump.net is intermittently unreachable (connection resets /
# exit 56, 504s, timeouts -- seen both from CI runners and locally), and
# no mirror of the JSON API exists, so every API call goes through two
# retry layers: curl's own --retry-all-errors, plus an outer loop that
# also re-fetches when the body is not the JSON shape we expect (a proxy
# error page can come back with HTTP 200). fetch_json succeeds only when
# the downloaded file parses as JSON AND the given check expression
# (evaluated with d = the parsed document) is truthy.
fetch_json() {
    local url="$1" out="$2" check="$3" attempt
    for attempt in 1 2 3 4; do
        if curl -sS --fail --retry 5 --retry-all-errors --retry-delay 5 \
                --retry-max-time 300 --connect-timeout 20 \
                -o "$out" "$url" \
           && python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)' "$out" "$check"; then
            return 0
        fi
        echo "::warning::fetch_json attempt $attempt failed for $url"
        sleep 10
    done
    echo "::error::fetch_json: giving up on $url after 4 attempts"
    return 1
}
# --- end network helpers ---

if [ -z "$UUID" ]; then
    echo "== Resolving newest Windows 11 ARM64 build (search='$SEARCH') via UUP dump API =="
    fetch_json "$API/listid.php?search=$SEARCH&sortByDate=1" "$WORK/listid.json" \
        '"builds" in d.get("response", {})'
    UUID="$(python3 - "$WORK/listid.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
builds = d["response"]["builds"]
# NOTE: "builds" is keyed by an opaque row index ("14", "60", ...), NOT
# by UUID -- the update UUID lives in the "uuid" field of each entry.
# An earlier version of this script used the dict key as the UUID and
# resolved to nonsense ids like "60".
# WARNING: never put an apostrophe (or any single quote) anywhere in
# this heredoc body, not even in comments or Python strings. The heredoc
# sits inside a "$( )" command substitution, and the macOS runner
# /bin/bash 3.2 parser mis-tracks quotes there: one stray apostrophe
# makes the whole script die at parse time with exit code 2 before a
# single command runs (image workflow run #4, 2026-11-19).
cands = []
for b in builds.values():
    title = b.get("title", "")
    uuid = b.get("uuid", "")
    if b.get("arch") == "arm64" and title.startswith("Windows 11") and uuid:
        cands.append((b.get("created") or 0, uuid, title))
cands.sort(reverse=True)
if not cands:
    sys.exit("no Windows 11 arm64 build matched the search")
print(f"newest match: {cands[0][2]} (uuid {cands[0][1]})", file=sys.stderr)
sys.stdout.write(cands[0][1])
PYEOF
)"
    echo "Resolved UUP build UUID: $UUID"
fi

# A resolved or user-supplied id that is not UUID-shaped can only fail
# downstream; reject it here where the cause is obvious.
if ! [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "::error::'$UUID' is not a valid UUP build UUID"
    exit 1
fi

echo "== Checking language availability ($LANG_CODE) =="
# Advisory only (get.php below is the real gate), so a fetch failure here
# must not kill the run -- but go through the same retrying fetcher.
if fetch_json "$API/listlangs.php?id=$UUID" "$WORK/listlangs.json" \
        '"langList" in d.get("response", {})'; then
    python3 - "$WORK/listlangs.json" "$LANG_CODE" <<'PYEOF' || true
import json, sys
langs = json.load(open(sys.argv[1]))["response"]["langList"]
if sys.argv[2] not in langs:
    print(f"::warning::language '{sys.argv[2]}' not in listlangs response "
          f"({len(langs)} languages listed); continuing (get.php will fail loudly if unusable)")
PYEOF
else
    echo "::warning::listlangs fetch failed for $UUID; continuing without the language check"
fi

echo "== Fetching UUP file list (lang=$LANG_CODE edition=$EDITION) =="
fetch_json "$API/get.php?id=$UUID&lang=$LANG_CODE&edition=$EDITION" "$WORK/uup_files.json" \
    '"files" in d.get("response", {}) and len(d["response"]["files"]) > 0'

echo "== Downloading UUP set from Microsoft update servers =="
rm -rf "$UUP_DIR"
mkdir -p "$UUP_DIR"
python3 - "$WORK/uup_files.json" "$UUP_DIR" <<'PYEOF'
import json, sys
from pathlib import Path
d = json.load(open(sys.argv[1]))
files = d["response"]["files"]
outdir = Path(sys.argv[2])
with open(outdir / "aria2.txt", "w") as f:
    for name, meta in files.items():
        f.write(meta["url"] + "\n")
        f.write(f"  out={name}\n")
        if meta.get("sha1"):
            f.write(f"  checksum=sha-1={meta['sha1']}\n")
print(f"{len(files)} UUP files queued")
PYEOF
if command -v aria2c >/dev/null 2>&1; then
    aria2c -i "$UUP_DIR/aria2.txt" -d "$UUP_DIR" -j 5 -x 1 --file-allocation=none
else
    echo "::warning::aria2c not found; falling back to sequential curl (SHA-1 verified afterwards)"
    python3 - "$WORK/uup_files.json" "$UUP_DIR" <<'PYEOF'
import json, subprocess, sys
from pathlib import Path
d = json.load(open(sys.argv[1]))
outdir = Path(sys.argv[2])
for name, meta in d["response"]["files"].items():
    dest = outdir / name
    if not dest.exists():
        subprocess.run(["curl", "-L", "--fail", "--retry", "5", "--retry-all-errors", "--retry-delay", "5", "-o", str(dest), meta["url"]], check=True)
    if meta.get("sha1"):
        got = subprocess.check_output(["shasum", "-a", "1", str(dest)]).split()[0].decode()
        if got.lower() != meta["sha1"].lower():
            sys.exit(f"SHA-1 mismatch for {name}")
print("curl fallback download + SHA-1 verification complete")
PYEOF
fi
du -sh "$UUP_DIR"

# The converter refuses to run unless cabextract, wimlib-imagex, chntpw
# and genisoimage/mkisofs are all within reach. cabextract and wimlib
# come from the workflow's brew step; cover the two that step cannot
# guarantee: mkisofs (in the cdrtools formula) and chntpw (no Homebrew
# formula exists any more -- built from pinned source instead).
if ! command -v genisoimage >/dev/null 2>&1 && ! command -v mkisofs >/dev/null 2>&1; then
    echo "== Installing cdrtools (provides mkisofs) for the converter =="
    brew install cdrtools
fi
if ! command -v chntpw >/dev/null 2>&1; then
    bash "$ROOT/scripts/ci/install_chntpw.sh" "$WORK/tools"
    export PATH="$WORK/tools/bin:$PATH"
fi
command -v chntpw

echo "== Converting UUP set to ISO (official UUP dump converter) =="
CONV_DIR="$WORK/converter"
rm -rf "$CONV_DIR"
git clone --depth 1 https://git.uupdump.net/uup-dump/converter.git "$CONV_DIR" \
    || git clone --depth 1 https://github.com/uup-dump/converter.git "$CONV_DIR"
# The converter contract (convert.sh from uup-dump/converter v0.7.3,
# verified against the cloned source and by local test runs):
#   convert.sh [compression] [uups_directory] [create_virtual_editions]
# $1 is the compression type ("wim" or "esd"), NOT a path; $2 is the
# folder holding the UUP files (default: a "UUPs" folder under the
# current directory); $3 toggles virtual editions (default 0). The ISO
# is written into the *current* directory under a fully upper-cased
# name: the converter runs tr "[:lower:]" "[:upper:]" over the whole
# file name, extension included, producing e.g.
# 26100.9974_PROFESSIONAL_ARM64_EN-US.ISO -- so the search below must
# use -iname, because a case-sensitive -name '*.iso' can never match.
# An earlier version of this script tried two other invocation shapes
# (no arguments from inside the UUP folder, which makes the converter
# look for a UUPs subfolder; and UUP path + ISO name as arguments,
# which it reads as an invalid compression type). Both die instantly
# in its argument checks, which is why image workflow run #5 produced
# no ISO. Run it once, from a scratch directory, with its output in a
# dedicated log, and judge the result by the exit code plus the
# case-insensitive ISO search.
CONV_RUN="$WORK/convert-run"
CONV_LOG="$WORK/converter.log"
rm -rf "$CONV_RUN"
mkdir -p "$CONV_RUN"
CONV_RC=0
( cd "$CONV_RUN" && bash "$CONV_DIR/convert.sh" wim "$UUP_DIR" ) > "$CONV_LOG" 2>&1 || CONV_RC=$?
echo "-- converter log (last 30 lines) --"
tail -n 30 "$CONV_LOG" || true
ISO_PATH="$(find "$CONV_RUN" -iname '*.iso' -type f 2>/dev/null | head -1 || true)"
if [ -z "$ISO_PATH" ]; then
    ISO_PATH="$(find "$WORK" -iname '*.iso' -type f 2>/dev/null | head -1 || true)"
fi
if [ "$CONV_RC" -ne 0 ] || [ -z "$ISO_PATH" ] || [ ! -f "$ISO_PATH" ]; then
    echo "::error::UUP converter failed (exit code $CONV_RC, ISO found: '${ISO_PATH:-none}'); converter log tail follows"
    tail -n 15 "$CONV_LOG" 2>/dev/null | while IFS= read -r convline; do
        printf '::error::%s\n' "$(printf '%s' "$convline" | sed -e 's/%/%25/g' -e 's/\r/%0D/g')"
    done
    ls -la "$WORK" "$CONV_RUN" "$UUP_DIR" || true
    exit 1
fi
echo "Converter produced: $ISO_PATH"

echo "== Rebuilding retail-layout ESD from ISO =="
bash "$ROOT/scripts/ci/build_synthetic_esd.sh" "$ISO_PATH" "$OUT_ESD"

rm -rf "$UUP_DIR" "$CONV_DIR" "$CONV_RUN" "$ISO_PATH"
ls -lh "$OUT_ESD"
echo "=== ESD ready (UUP route) ==="
FETCH_COMPLETED=1
