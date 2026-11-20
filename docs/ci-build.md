# CI build (no Mac required)

This fork adds the CI packaging the upstream repo lacks, modelled on
Henge's `build-henge.yml` / `package_ipa.sh` (both GPL-2.0-or-later).

## What was added

- `.github/workflows/build-windowsios.yml` — manual (`workflow_dispatch`)
  GitHub Actions workflow with two jobs:
  - `build-ipa`: on an `xcode-27` runner, cross-builds the iOS deps
    (`scripts/build_ios_deps.sh`, with `HUSK_REF` pointed at a Husk
    checkout), builds `make ios-lib test-core`, then packages an
    **unsigned, ad-hoc signed** `WindowsiOS.ipa` as an artifact.
    The upstream `ios/project.yml` hard-codes the author's team/profile/
    identity; `ios/scripts/package_ipa.sh` overrides them on the
    xcodebuild command line (`CODE_SIGNING_ALLOWED=NO`, empty
    team/identity/profile), so `project.yml` is untouched.
  - `guest-helpers`: builds the freestanding AArch64 Win32 helpers
    (`build/opt_hive_arm64.exe`, `build/WinIOSBrowser.exe`) that upstream
    ships as sources only. `scripts/build_guest_helpers.sh` reconstructs
    the build with clang + lld and `llvm-dlltool` import libraries
    generated from `tools/win32/*.def` (function lists mirror the
    sources' own `__declspec(dllimport)` declarations; entry points are
    `mainCRTStartup` / `WinMainCRTStartup` as defined in the sources).
- `ios/scripts/package_ipa.sh` — unsigned build + ad-hoc IPA packaging.
  `WINIOS_ENTITLEMENTS` selects the entitlements file.
- `ios/WindowsiOS.personal.entitlements` — `get-task-allow` plus
  `com.apple.developer.kernel.increased-memory-limit`, for a free personal
  team (mirrors Henge's `Henge.personal.entitlements`). Whether the
  memory-limit entitlement survives re-signing depends on the profile the
  sideloader builds; without it the app falls back to smaller guest RAM.

## Running it

1. Keep the fork **public** (macOS runner minutes are unlimited on public
   repos, 10x-billed on private ones).
2. Actions tab → **Build WindowsiOS IPA** → Run workflow.
3. Download the `WindowsiOS-ipa-*` artifact, unzip, and sideload the IPA
   (e.g. SideInstaller). The `WindowsiOS-guest-helpers-*` artifact is for
   the later Windows image provisioning phase.
