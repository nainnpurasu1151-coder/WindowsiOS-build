# Phase 2: build the Windows 11 machine image in GitHub Actions

Goal: produce `windows11.hvsparse` + `code.fd` + `vars.fd` (the files the
app expects in `Documents/Machines/Win11`) without a Mac, by running the
upstream provisioning flow on GitHub-hosted macOS runners.

## How it works

Upstream's flow (`scripts/provision_windows_arm64.py` +
`scripts/optimize_windows_lite.py`) orchestrates from macOS Python but
does the real work inside the project's own engine (`build/winvm`):
WinPE boots in the VM, DISM applies the image, `bcdboot` writes the UEFI
boot config, a second boot runs specialize/OOBE unattended, and the
optimizer boots WinPE again for offline AppX removal + registry hive
surgery with `build/opt_hive_arm64.exe`. It therefore needs a macOS host
(hdiutil/diskutil, Homebrew paths, APFS clone) -- a Windows runner
cannot substitute. GitHub's macOS arm64 runners match that shape.

The workflow `.github/workflows/build-image.yml` splits the flow into
one job per stage, chained by artifacts, so no job nears the
360-minute hosted limit:

| job | does | in -> out |
|---|---|---|
| `helpers` / `fetch-helpers` | guest helper exes (`opt_hive_arm64.exe`, `WinIOSBrowser.exe`) | sources / an earlier IPA-workflow run -> `guest-helpers` artifact |
| `prepare` | runner probe (CPU/RAM/free disk, fail-fast) -> fetch media -> `make all` -> installer image | UUP set or ESD URL -> `image-inputs`, `windows-esd` artifacts |
| `phase1` | WinPE: GPT partition, DISM apply, offline registry, bcdboot | -> `phase1-out` (hvsparse-packed disk + post-DISM vars) |
| `phase2` | first boot: specialize, OOBE, autologon, clean shutdown | -> `phase2-out` (packed disk + `vars_clean.fd` + `code.fd`) |
| `optimize` | WinPE optimizer (AppX strip + hive surgery), final `hvsparse pack` | -> **`WindowsiOS-Win11-machine`** (`windows11.hvsparse`, `code.fd`, `vars.fd`) |

Disk images travel between jobs packed with the project's own
`build/hvsparse` (zero-skipping), which keeps artifact sizes near the
real data size instead of the 32 GB logical size.

### Media source (no manual ESD download)

`scripts/ci/fetch_uup_esd.sh` automates what used to be the one manual
piece. Default route: the UUP dump JSON API
(`api.uupdump.net/listid.php` -> `listlangs.php` -> `get.php`) resolves
a Windows 11 ARM64 consumer build; the file set is downloaded from
Microsoft's own update servers and SHA-1-verified; the official UUP
dump converter builds an ISO; `scripts/ci/build_synthetic_esd.sh` then
rebuilds an ESD with the exact retail layout the provisioning scripts
hard-code (index 1 = setup files, 2 = WinPE, 6 = Pro). Because the
layout is constructed, it is independent of the source media's own
index numbering -- a ja-JP set works the same way (the unattend
locale/user inside the image stays upstream's en-US/Ammaar for now;
localizing it is a separate small change). Setting the `esd_url`
input bypasses UUP and downloads a retail ESD directly.

### Fork patches that make this possible

`provision_windows_arm64.py` / `optimize_windows_lite.py` gained
env-only knobs; with nothing set they behave exactly like upstream:

- `WINIOS_PROVISION_STAGE` = `all|installer|phase1|phase2`
- `WINIOS_PHASE1_MINUTES` / `WINIOS_PHASE2_MINUTES` / `WINIOS_OPT_MINUTES`
  (upstream caps: 40 / 60 / 25 -- sized for the author's M-series Mac)
- `WINIOS_VM_RAM` (upstream: 4096)

## Feasibility notes (checked 2026-11-19)

- **Minutes**: public repo -> hosted minutes are unlimited, macOS
  included. Keep the fork public (private macOS minutes bill at 10x).
- **Per-job limit**: 360 min. Worst job is `phase2` (cap 240 min +
  ~30 min setup/transfer), then `phase1` (150 + ~30).
- **CPU/RAM**: macOS arm64 standard runner = 3 vCPU (M1), 7 GB RAM
  (GitHub runner reference). winvm asks for 4 vCPUs (oversubscribed,
  works, slower -- hence the raised caps) and 4096 MB guest RAM by
  default; if a phase dies from memory pressure, re-run with
  `vm_ram=3072`.
- **Disk**: GitHub's reference lists 14 GB SSD for standard runners,
  which would be impossible (the pipeline peaks around 30 GB of real
  data: ESD ~5.5 GB, installer ~6.4 GB, installed image ~12-15 GB,
  optimizer PE ~2.2 GB, outputs ~7 GB). The `prepare` job therefore
  probes `df` first and fails fast below `min_free_gb` (default 55)
  with the measured number in the run annotations, so the first run
  settles the real capacity. Per-job hygiene also helps: the ESD is
  deleted by the fetch script's UUP cleanup, phase jobs never hold the
  installer + ESD + two images at once, and transfers are hvsparse-packed.
- **hdiutil/diskutil on hosted runners** and the UUP converter's macOS
  script are the two untested-on-CI pieces; both surface early
  (`prepare` job) with logs/screenshots in the `*-diagnostics` artifacts.

## What you (the repo owner) need to do

The workflow file cannot be pushed by the GitHub App (no Workflows
permission), so add it by hand once -- everything else (scripts, this
doc) is already in the fork:

1. Open the fork on github.com -> **Add file -> Create new file**.
2. File name (exactly):
   `.github/workflows/build-image.yml`
3. Paste the contents of `.github/workflows/build-image.yml` from the
   working copy -> **Commit changes** (to `main`).
4. **Actions** tab -> **Build Windows 11 machine image** ->
   **Run workflow**. First run: leave every input at its default
   (UUP route, en-us, ram 4096). If you already have a successful
   `WindowsiOS-guest-helpers-*` artifact from the IPA workflow, you
   may paste that run's ID into `helpers_run_id`; leaving it empty
   just builds the helpers again inside this workflow.
5. When it finishes, download the **`WindowsiOS-Win11-machine`**
   artifact: `windows11.hvsparse` + `code.fd` + `vars.fd` are the
   Phase 3 inputs.

If a job fails, open its `*-diagnostics` artifact (VM log + last
screenshot) -- the phase scripts already screenshot every 20 s, which
is the fastest way to see where WinPE/Windows stopped.

## Run #8 postscript: the skipped-stages bug (found 2026-11-20)

Run #8 (ID 44523453406, esd-reuse configuration) finished with the run
itself marked **success**, yet `phase1`, `phase2` and `optimize` were
all **skipped** -- the final `WindowsiOS-Win11-machine` artifact was
never produced, while `installer` succeeded and its `image-inputs`
artifact (6.25 GB) was saved. The mechanism: GitHub Actions propagates
a `skipped` result through the needs graph to any job whose `if` does
not contain a status check function. `installer` survived its skipped
ancestor (`fetch-esd`) because its `if` uses `always()`, but `phase1`
-- whose only direct need was the successful `installer` and which had
no `if` at all -- was skipped anyway, and the skip then chained to
`phase2` and `optimize`. The fix gives `phase1` / `phase2` / `optimize`
explicit result-based conditions
(`!cancelled() && needs.<job>.result == 'success'`, with `phase1`
accepting either the `installer` or the new `fetch-inputs` job, and
either the `helpers` or `fetch-helpers` job), and adds an
`inputs_run_id` input plus a `fetch-inputs` job that re-imports a
previous run's `image-inputs` (and its `windows-esd`, which the
optimizer needs, unless `esd_run_id` is set) so the pipeline resumes
directly at `phase1`. Run #8 is the intended first source:
`inputs_run_id=44523453406`, `esd_run_id` left empty.
