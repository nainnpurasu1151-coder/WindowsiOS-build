#!/bin/zsh
# Builds WindowsiOS for iOS and writes ~/Desktop/WindowsiOS.ipa.
# Adapted from Henge's ios/scripts/package_ipa.sh (GPL-2.0-or-later):
# unsigned xcodebuild, then ad-hoc signed inside out with the entitlements
# file named by WINIOS_ENTITLEMENTS (default WindowsiOS.entitlements in
# ios/). The sideloader (SideInstaller, SideStore, ...) re-signs it with the
# user's own certificate on install and keeps the entitlements it can;
# increased-memory-limit (WindowsiOS.personal.entitlements) only survives
# if the signing certificate/profile carries it.
#
# Signing settings hard-coded in ios/project.yml (the upstream author's
# DEVELOPMENT_TEAM / profile / identity) are overridden on the xcodebuild
# command line: CODE_SIGNING_ALLOWED=NO plus empty team/identity/profile.
#
# Prerequisites (see .github/workflows/build-windowsios.yml):
#   scripts/build_ios_deps.sh has staged ios/deps/
#   make ios-lib has produced build/ios/libwinvm.a
set -e
# In zsh an unmatched glob is a fatal "no matches found" error (unlike
# bash), which aborted this script after a successful build in CI run #1,
# back when the app shipped no frameworks or extensions. NULL_GLOB makes
# them expand to nothing instead. (Since Phase 4 the app ships StikJIT in
# Frameworks/ and the JIT helper in PlugIns/, so the loops below do match;
# NULL_GLOB stays as belt and braces.)
setopt NULL_GLOB
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/ios"
OUT="${WINIOS_IPA_OUT:-$HOME/Desktop/WindowsiOS.ipa}"
cd "$ROOT"

# CI diagnostics: which Xcode / iOS SDK is actually selected. Emitted as
# workflow annotations too, so they are readable without the raw job log.
echo "xcodebuild: $(xcodebuild -version 2>/dev/null | head -1)"
echo "iphoneos SDK: $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo unknown)"
echo "::notice::xcodebuild: $(xcodebuild -version 2>/dev/null | head -1) / iphoneos SDK: $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo unknown)"

# Preflight: every library the app links must have been staged by the
# earlier steps. scripts/build_ios_deps.sh copies libs with an
# "if [ -f ... ]" guard, so a lib its build silently skipped would
# otherwise surface only as an opaque xcodebuild link error.
missing=0
for lib in "$ROOT/build/ios/libwinvm.a" \
           "$IOS/deps/lib/libslirp.a" "$IOS/deps/lib/libglib-2.0.a" \
           "$IOS/deps/lib/libintl.a" "$IOS/deps/lib/libpcre2-8.a" \
           "$IOS/deps/lib/libffi.a" "$IOS/deps/lib/libhusk_rppairing.a"; do
    if [ ! -f "$lib" ]; then
        echo "::error::Missing build input: ${lib#$ROOT/} (earlier CI step did not stage it)"
        missing=1
    fi
done
if [ ! -d "$IOS/deps/StikJIT.xcframework" ]; then
    echo "::error::Missing build input: ios/deps/StikJIT.xcframework (earlier CI step did not stage it)"
    missing=1
fi
[ $missing -eq 0 ] || { echo "==> missing build inputs; refusing to package" >&2; exit 1; }

xcodegen generate --spec ios/project.yml >/dev/null
# xcodegen writes the project next to the spec; fall back to the cwd copy.
PROJ="ios/WindowsiOS.xcodeproj"
[ -d "$PROJ" ] || PROJ="WindowsiOS.xcodeproj"
[ -d "$PROJ" ] || { echo "::error::xcodegen did not produce WindowsiOS.xcodeproj"; exit 1; }
DD="$IOS/build/DerivedData"
mkdir -p "$IOS/build"
xcodebuild -project "$PROJ" -scheme WindowsiOS -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    build > "$DD.buildlog" 2>&1 || {
    # Never package what an older build left behind.
    grep -E "error:|BUILD" "$DD.buildlog" | sort -u
    # Surface the first unique errors as annotations (readable via the
    # public API / run page without opening the raw log).
    grep -E "error:" "$DD.buildlog" | sort -u | head -12 | while IFS= read -r line; do
        esc="${line//\%/%25}"
        echo "::error::xcodebuild: ${esc:0:300}"
    done
    tail -30 "$DD.buildlog"
    echo "==> the build failed; nothing packaged" >&2
    exit 1
}
grep -E "BUILD" "$DD.buildlog" || true
APP="$DD/Build/Products/Release-iphoneos/WindowsiOS.app"
rc=0
for f in "$APP/WindowsiOS" "$APP/henge-jit.js"; do
    if [ -f "$f" ]; then printf "  ok       %s\n" "${f#$APP/}"; else echo "  MISSING  ${f#$APP/}" >&2; rc=1; fi
done
[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

STAGE="$(mktemp -d "$DD/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
ENT="$STAGE/entitlements.plist"
# WINIOS_ENTITLEMENTS picks another file (WindowsiOS.personal.entitlements
# for a free personal team, mirroring Henge's Henge.personal.entitlements).
cp "$IOS/${WINIOS_ENTITLEMENTS:-WindowsiOS.entitlements}" "$ENT"
SAPP="$STAGE/Payload/WindowsiOS.app"
# plutil -insert fails when the key already exists and -replace fails when
# it does not; try insert, fall back to replace.
plist_set() { plutil -insert "$1" -string "$2" "$3" 2>/dev/null || plutil -replace "$1" -string "$2" "$3"; }
plist_set WindowsiOSBuildCommit "$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" "$SAPP/Info.plist"
plist_set WindowsiOSBuildDate "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SAPP/Info.plist"
sign() { codesign --force --sign - --timestamp=none "$@"; }
for fw in "$SAPP"/Frameworks/*.framework; do [ -d "$fw" ] && sign "$fw"; done
for ex in "$SAPP"/PlugIns/*.appex; do [ -d "$ex" ] && sign "$ex"; done
sign --entitlements "$ENT" "$SAPP"
EMBEDDED=$(codesign -d --entitlements - "$SAPP" 2>&1 || true)
# Every key the entitlements file asks for must be in the signature.
for k in $(plutil -convert json -o - "$ENT" | python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)))'); do
    grep -q "$k" <<< "$EMBEDDED" || { echo "==> $k did not embed; refusing to package" >&2; exit 1; }
done
( cd "$STAGE" && zip -qry "$STAGE/package.tmp" Payload )
mv -f "$STAGE/package.tmp" "$OUT" # atomic: a half-written IPA never sits where the good one was
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
