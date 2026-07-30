# Audit Findings — playos-refdistro

> **Date:** 2026-07-29
> **Scope:** Full repository audit: build pipeline, ISO creation, disk image, init systems, services, documentation
> **Method:** Line-by-line review of all scripts, configs, init files, shared libraries, docs, and latest build log
>
> **Second pass (2026-07-29):** F-013–F-028 added — cross-distro comparison of the
> Alpine/Arch/Ubuntu-host pipelines after F-001–F-012 were resolved. Focus areas:
> supply-chain verification asymmetry, shared-vs-duplicated logic, Arch ISO
> bootability, and build-container statefulness.

## Status Legend

| Status | Meaning |
|---|---|
| `open` | Not yet investigated or addressed |
| `in_progress` | Actively being worked on |
| `resolved` | Fixed and verified |
| `wontfix` | Accepted as-is, intentional |
| `false_positive` | Investigation showed no actual issue |

---

## Findings

### F-001 — amdgpu firmware not detected in initramfs 🔴

- **Severity:** High
- **Status:** resolved
- **File:** `scripts/build-disk-image-alpine.sh`, `alpine/amdgpu-firmware.files`, `alpine/nvidia-firmware.files`
- **Evidence:** `build.log` — `WARNING: amdgpu firmware MISSING from initramfs`

**Description:** The firmware verification logic correctly detects the initramfs compression format (magic bytes: gzip=1f8b, xz=fd377a58, lz4=04224d18) and decompresses+greps for `lib/firmware/amdgpu/`, but does not find it. GPU firmware IS installed in both the build container (`/lib/firmware/amdgpu/`) and target root (`$MNT/lib/firmware/amdgpu/`). The amdgpu kernel module IS included in the initramfs (via `alpine/amdgpu.modules`).

**Root cause:** `amdgpu-firmware.files` and `nvidia-firmware.files` contained bare directory paths (`lib/firmware/amdgpu`) which Alpine's mkinitfs interprets as a single directory entry — not a recursive file include. To include files, glob patterns like `lib/firmware/amdgpu/*.bin` are required.

**Resolution:** 
1. Updated `alpine/amdgpu-firmware.files` to include `lib/firmware/amdgpu/*.bin` glob
2. Updated `alpine/nvidia-firmware.files` to include `lib/firmware/nvidia/*` glob
3. Added `mkinitfs -F` flag for automatic firmware inclusion as a safety net
4. Improved verification: caches decompressed listing, checks both amdgpu and nvidia firmware, reports file counts

---

### F-002 — Fragile sed injection for ISO rebuild workaround 🔴

- **Severity:** High
- **Status:** resolved
- **File:** `scripts/build-alpine-iso.sh`
- **Lines:** sed injection into `mkimg.base.sh`

**Description:** Alpine's mkimage.sh uses xorriso inside nspawn, which corrupts the apkovl. The workaround sed-injected a backup of DESTDIR before xorriso runs. This depended on exact upstream formatting.

**Resolution:** Replaced with a version-pinned `.patch` file (`patches/aports-mkimage.patch`), applied via `scripts/apply-aports-patches.sh` using `git apply`. The patch fails at build time if upstream changes, instead of silently producing a corrupted ISO. See `patches/README.md` for regeneration procedure.

---

### F-003 — `cp -Lrs` → `cp -rL` sed replacement is fragile 🟡

- **Severity:** Medium
- **Status:** resolved
- **File:** `scripts/build-alpine-iso.sh`

**Description:** Another sed patch replaced `cp -Lrs` with `cp -rL` because nspawn bind mounts don't support hardlinks across filesystem boundaries.

**Resolution:** Included in the same `.patch` file as F-002 (`patches/aports-mkimage.patch`). Applied via `git apply` which fails cleanly if the pattern changes upstream.

---

### F-004 — Duplicate disk image artifact naming 🟡

- **Severity:** Medium
- **Status:** resolved
- **File:** `scripts/build-iso-ubuntu.sh`, `scripts/build-disk-image-alpine.sh`

**Description:** The `out/` directory contained both `playos-gpt-v3.24-x86_64.img.zst` and `playos-gpt-alpine-v3.24-x86_64.img.zst`. Different scripts referenced different names.

**Resolution:** Unified to `playos-gpt-alpine-${ALPINE_BRANCH}-${ARCH}` format everywhere. The distro prefix is kept to support multi-distro artifact co-existence. Updated `build-disk-image-alpine.sh` standalone IMAGE_NAME to match the orchestrator convention.

---

### F-005 — build.log contains raw ANSI escape sequences 🟡

- **Severity:** Low
- **Status:** resolved
- **File:** `scripts/build-iso-ubuntu.sh`, `scripts/build-disk-image-alpine.sh`, `scripts/build-alpine-iso.sh`

**Description:** The build log had raw ANSI terminal escape codes from progress bars, cursor movements, and color codes. This made it hard to grep programmatically or parse in CI/CD.

**Resolution:** Added `TERM=dumb` to all nspawn invocations in `build-iso-ubuntu.sh`. Added `--no-progress` to all `apk add` commands in `build-disk-image-alpine.sh` and `build-alpine-iso.sh`.

---

### F-006 — `playos-async` runlevel is reserved but empty 🟡

- **Severity:** Medium
- **Status:** resolved
- **File:** `alpine/genapkovl-playos.sh`, `alpine/init.d/playos-async-trigger`, `alpine/init.d/playos-compositor`

**Description:** The `playos-async` runlevel is created but contains no services. NetworkManager, iwd, and sshd currently start in `playos-visual` or `default` alongside the compositor.

**Resolution:** Moved NetworkManager, iwd, and sshd from `playos-visual` to `playos-async`. Created `playos-async-trigger` init script that polls for `/run/playos-visual-ready` (written by the compositor after successful startup) and activates the async runlevel via `openrc playos-async`. Updated both the ISO (genapkovl) and disk image (build-disk-image-alpine.sh) paths. Updated `build-playos-components.sh` to install the trigger script. Updated `docs/architecture/boot-and-services.md`.

---

### F-007 — No initramfs firmware verification in Arch path 🟡

- **Severity:** Medium
- **Status:** resolved
- **File:** `scripts/build-disk-image-arch.sh`

**Description:** The Alpine build had firmware verification logic (F-001), but the Arch path had no equivalent. It ran `mkinitcpio` with `MODULES=(amdgpu ...)` but didn't verify firmware was actually included.

**Resolution:** Added firmware verification to `build-disk-image-arch.sh` mirroring the Alpine approach: magic-byte compression detection (including zstd for mkinitcpio), decompress + cpio listing, grep for amdgpu entries with file count. Displays first 20 files on failure for diagnostics.

---

### F-008 — tomlplusplus ext4/xfs segfault workaround 🟡

- **Severity:** Medium
- **Status:** investigated (workaround accepted)
- **File:** `alpine/init.d/playos-compositor`, `arch/systemd/playos-compositor.service`, `playos-platform-api/src/device_profile.cpp`

**Description:** Both the OpenRC init script and systemd unit copy device profiles from `/etc/playos/device-profiles/` (ext4) to `/run/playos/profiles/` (tmpfs) because "tomlplusplus segfaults when reading from ext4/xfs-backed filesystem paths."

**Investigation:** `device_profile.cpp` reads the entire file into a `std::string` via `std::ifstream` + `std::stringstream` before calling `toml::parse(content)`. The parsing operates on in-memory data, ruling out raw file I/O. The segfault is likely a musl-specific interaction: musl's `std::ifstream` implementation, ext4's block-layer behavior, or a combination. Without a minimal C++ reproducer on an actual ROG Ally with Alpine/musl, root-causing further is impractical. tomlplusplus v3.4.0 has no known musl-specific fixes.

**Decision:** Keep the tmpfs workaround (~2ms copy, negligible boot impact). File an upstream investigation issue. If the segfault is reproduced in a controlled environment, create a minimal reproducer and file a tomlplusplus bug.

---

### F-009 — hid-asus-ally pinned to commit hash, not tag 🟢

- **Severity:** Low
- **Status:** resolved (documented)
- **File:** `scripts/build-hid-asus-ally.sh`

**Description:** The build script clones the repo then checks out commit `71648145` because tag `20240910` points to a non-commit object. A force-push to the upstream repo would break the shallow clone.

**Resolution:** Documented the recommendation to fork `uejji/hid-asus-ally` under PlayOS-Foundation org. The existing pinned-commit workflow is correct; changing `HID_REPO` to a PlayOS-Foundation fork eliminates the force-push risk. Alternative: vendor the source tarball at the pinned commit.

---

### F-010 — Compression double-handling confusion 🟢

- **Severity:** Low
- **Status:** resolved
- **File:** `scripts/build-iso-ubuntu.sh`, `scripts/build-alpine-iso.sh`, `docs/architecture/image-pipeline.md`

**Resolved.** Added "Compression ownership" table to `docs/architecture/image-pipeline.md` documenting: (1) the orchestrator (`build-iso-ubuntu.sh`) is the sole owner of zstd compression, using `zstd -f -T0 --rm -12`; (2) the distro-specific ISO scripts only copy the pre-compressed `.img.zst` into the ISO staging tree — they do not compress anything; (3) filename convention and why compression is owned by the orchestrator (disk space, single source of truth).

---

### F-011 — Arch ISO path is cleaner than Alpine ISO path 🟢

- **Severity:** Low (observation)
- **Status:** noted (deferred)
- **File:** `scripts/build-arch-iso.sh` vs `scripts/build-alpine-iso.sh`

**Description:** The Arch ISO path assembles an ISO with direct `xorriso` — clean, readable, no patches. The Alpine path requires cloning aports, installing mkimage profiles, applying 4+ sed patches, running mkimage.sh, then rebuilding the ISO from a backup. The Arch approach could serve as a model.

**Impact:** Maintenance burden on the Alpine path.

**Suggested fix:** Evaluate whether the Alpine ISO can be built with direct xorriso (like Arch). This would eliminate the sed patches (F-002, F-003) and the rebuild workaround. The only Alpine-specific need is the modloop and apkovl — both can be assembled manually.

---

### F-012 — No automated CI validation pipeline 🟢

- **Severity:** Low
- **Status:** resolved
- **File:** `.github/workflows/ci.yml`, `scripts/verify-build.sh`, `scripts/test-disk-image-qemu.sh`

**Description:** Validation scripts exist (3-phase verify-build + QEMU tests for disk image and ISO), but they were manual with no GitHub Actions workflow.

**Resolution:** Added `.github/workflows/ci.yml` with 4 jobs: build (Alpine disk image + ISO via nspawn), verify (GPT/filesystem integrity checks), qemu-boot (UEFI boot test with serial marker detection), and summary. Triggers on PR to main, manual dispatch, and nightly. Includes amdgpu firmware warning check in build output.

---

### F-013 — Arch bootstrap tarball is not checksum/signature verified 🔴

- **Severity:** High
- **Status:** open
- **File:** `scripts/setup-ubuntu-build-host.sh` (`setup_arch`)

**Description:** The Alpine path downloads the minirootfs and verifies it against the
published `.sha256` before extraction. The Arch path downloads
`archlinux-bootstrap-<ver>-x86_64.tar.zst` from `geo.mirror.pkgbuild.com` and extracts
it with **no checksum and no GPG verification**. This tarball is the root of trust for
every Arch build — a compromised or corrupted mirror response is imported silently.

**Suggested fix:** Download the accompanying `.sig`/`sha256sums` for the bootstrap
tarball and verify before extraction, mirroring the Alpine flow (fail closed).

---

### F-014 — CachyOS repositories have `SigLevel = Optional`; GPG key import is best-effort 🔴

- **Severity:** High
- **Status:** open
- **File:** `arch/pacman.conf`, `scripts/build-disk-image-arch.sh`

**Description:** `[cachyos]` and `[cachyos-znver4]` set `SigLevel = Optional`, so
packages from those repos — **including the kernel** — install without any signature
verification. Additionally, the CachyOS key (`F3B607488DB35A47`) is fetched over
unauthenticated HKP from `keyserver.ubuntu.com` with `|| true` fallbacks, and
`lsign-key` failures are also swallowed. The header comment in `pacman.conf` implies
the key matters; the configuration makes it irrelevant.

**Suggested fix:** Set `SigLevel = Required DatabaseOptional` for CachyOS repos;
bootstrap trust via the `cachyos-keyring` package over HTTPS or WKD key retrieval;
fail the build when the key cannot be imported.

---

### F-015 — Arch ISO cannot boot an OS; kernel selection is container-state dependent 🔴

- **Severity:** High
- **Status:** open
- **File:** `scripts/build-arch-iso.sh`, `arch/mkinitcpio.conf`

**Description:** Two compounding problems:

1. **Unbootable as an installer/live medium.** `mkinitcpio.conf` uses standard hooks
   (`base udev autodetect modconf block filesystems keyboard`) with no archiso hooks,
   yet the ISO loader entry supplies **no `root=` parameter** and instead passes
   `archisobasedir=playos archiso_http_srv=http://${pxe-server}/playos`. The
   `${pxe-server}` is written literally (escaped in the heredoc) and nothing expands
   it. The standard initramfs finds no root device and drops to an emergency shell.
2. **Cross-variant contamination.** The ISO kernel is copied from the *persistent
   build container's* `/boot` with deckify checked first. A previous deckify build
   leaves `vmlinuz-linux-cachyos-deckify` in the container, so a later cachyos-variant
   ISO silently bundles the deckify kernel.

**Suggested fix:** Decide the ISO's role: (a) pure artifact transport — drop the
pretend-boot entry and document it, or (b) bootable installer — add archiso hooks (or
a PlayOS install hook) and a real `root=`/`playos.install` flow. Generate the loader
entry from the *target image's* `/boot`, not the container's, and key the kernel
filename off `$KERNEL_VARIANT`.

---

### F-016 — EXIT trap clobbered in build-disk-image-alpine.sh 🟡

- **Severity:** Medium
- **Status:** open
- **File:** `scripts/build-disk-image-alpine.sh` (~line 63 vs ~line 200)

**Description:** Standalone mode sets `trap cleanup_loop EXIT` after mounting the
image, but the initramfs verification block later runs
`trap 'rm -f "$INITRAMFS_LISTING"' EXIT`, **replacing** the loop/mount cleanup. On any
failure after that point, the loop device and mounts leak. This is exactly the
single-EXIT-trap hazard the AGENTS.md combined-trap convention was written for — the
orchestrator follows it, this script doesn't.

**Suggested fix:** Use one combined trap function (as in `build-iso-ubuntu.sh`), or
remove the redundant trap (the listing file is already `rm -f`'d inline).

---

### F-017 — `shared/fstab-generate.sh` and `shared/device-profiles.sh` are dead code; inline copies have drifted 🟡

- **Severity:** Medium
- **Status:** open
- **File:** `shared/fstab-generate.sh`, `shared/device-profiles.sh`, `scripts/build-disk-image-alpine.sh`, `scripts/build-disk-image-arch.sh`

**Description:** Nothing sources these two shared modules. Both disk-image scripts
inline their own fstab and device-profile logic, and the copies have already diverged:
Alpine deploys only the `rog-ally` profile while Arch deploys *all* profiles; the Arch
fstab has a `PLACEHOLDER` fallback (F-018) the Alpine one lacks. This violates the
repo's own layout policy ("distro-specific code in `alpine/`/`arch/`; shared logic in
`shared/`").

**Suggested fix:** Delete the dead modules or — better — make both disk scripts source
them, unifying on the Arch "deploy all profiles" behaviour.

---

### F-018 — Arch fstab silently writes literal `PLACEHOLDER` UUIDs 🟡

- **Severity:** Medium
- **Status:** open
- **File:** `scripts/build-disk-image-arch.sh` (fstab heredoc)

**Description:** `UUID=${ROOT_UUID:-PLACEHOLDER}` means a missing env var produces a
build that *succeeds* but yields an unbootable image, discovered only at first boot.
The same script correctly hard-fails on `${DISK_MNT:?}` — the UUIDs deserve the same
treatment.

**Suggested fix:** `: "${ROOT_UUID:?}" "${EFI_UUID:?}" "${DATA_UUID:?}"` near the top
of the script.

---

### F-019 — Arch initramfs/kernel version derived from persistent build container 🟡

- **Severity:** Medium
- **Status:** open
- **File:** `scripts/build-disk-image-arch.sh` (`KERNEL_VER="$(ls /lib/modules/ | head -1)"`)

**Description:** The kernel version, initramfs inputs, and the kernel binary itself all
come from the *build container's* `/lib/modules` and `/boot` — and that container
(`.build/arch-rootfs`) persists across builds and variants. With multiple kernels
installed, `ls | head -1` can pick the wrong version, producing an initramfs/kernel
mismatch. The Alpine script reads `$MNT/lib/modules` (the target), which is correct.

**Suggested fix:** Read the version from the target root (`$MNT/lib/modules`) and pin
the expected version string from the pacman transaction; or reset the container's
kernel state per build.

---

### F-020 — PXE deploy is unconditional and fails the build on unprepared hosts 🟡

- **Severity:** Medium
- **Status:** open
- **File:** `scripts/build-iso-ubuntu.sh` (Phase 4)

**Description:** The deploy to `/var/www/html/playos` always runs: it assumes the
directory exists, assumes a `www-data` user exists (`chown -R www-data:www-data`), and
runs under `set -e` — so a successful build exits non-zero on any machine that isn't
also the PXE server. Separately, the Arch kernel copy matches only `vmlinuz-linux` /
`vmlinuz-linux-cachyos` — **deckify** builds (`vmlinuz-linux-cachyos-deckify`) fall
through to a warning and deploy without a kernel.

**Suggested fix:** Gate deploy behind `PLAYOS_PXE_DEPLOY=1` (or `--pxe`); create the
target dir or skip with a warning; handle the deckify kernel name (or copy
`vmlinuz-stable`, which the disk script already writes for all variants).

---

### F-021 — Arch image service gaps: no sshd, no NetworkManager, no WiFi baking 🟡

- **Severity:** Medium
- **Status:** open
- **File:** `scripts/build-disk-image-arch.sh`, `arch/systemd/`, `arch/packages*.x86_64`

**Description:** `openssh` and `networkmanager` are installed but neither
`sshd.service` nor `NetworkManager.service` is enabled — the Arch image boots with no
remote access and no networking until manual intervention. The orchestrator also
passes `PLAYOS_WIFI_SSID/PSK` into the Arch nspawn, but only the Alpine script consumes
them. First-frame parity between distros holds; debuggability parity does not.

**Suggested fix:** Enable `NetworkManager.service` and `sshd.service` (wanted-by
multi-user or a playos-async equivalent target), and port the WiFi profile baking from
the Alpine script.

---

### F-022 — Raylib tarball downloaded without checksum 🟢

- **Severity:** Low
- **Status:** open
- **File:** `scripts/build-playos-components.sh`

**Description:** `raylib-6.0.tar.gz` is fetched from GitHub and extracted with no
sha256 verification — inconsistent with the minirootfs verification and with the
hid-asus-ally pinned-commit discipline.

**Suggested fix:** Pin `RAYLIB_SHA256` next to `RAYLIB_VER` and verify after download.

---

### F-023 — APK repositories hardcode `v3.24`, ignoring `PLAYOS_ALPINE_BRANCH` 🟢

- **Severity:** Low
- **Status:** open
- **File:** `scripts/build-disk-image-alpine.sh` (repositories heredoc)

**Description:** The heredoc writes `alpine/v3.24/main|community` literally. Setting
`PLAYOS_ALPINE_BRANCH=v3.25` changes the image name and mkimage repos but **not** the
disk-image package source — a silent mismatch.

**Suggested fix:** Substitute `${ALPINE_BRANCH}` in the heredoc.

---

### F-024 — aports is branch-pinned, not commit-pinned 🟢

- **Severity:** Low
- **Status:** open
- **File:** `scripts/build-alpine-iso.sh`

**Description:** `git clone --depth 1 --branch 3.24-stable` tracks a moving branch.
Re-running an old build later can produce a different ISO (or fail the patch check by
design). Reproducibility requires recording the resolved commit in `metadata.json` and
optionally pinning `PLAYOS_APORTS_COMMIT`.

---

### F-025 — verify-build.sh: mixed-distro `out/` ambiguity and inverted vfat heuristic 🟢

- **Severity:** Low
- **Status:** open
- **File:** `scripts/verify-build.sh`

**Description:** (a) Distro detection picks `arch` if *any* arch image exists in
`out/`, while `head -1` finds may select the other distro's image/ISO — size limits
and PXE expectations can be applied to the wrong artifacts. (b) The ESP check passes
only when fsck output contains known cosmetic strings; a *clean* filesystem (or an
unexpected fsck failure mode) is reported as "ERRORS".

**Suggested fix:** Accept a distro argument (default from `PLAYOS_DISTRO`); rewrite
the vfat check to fail on fsck exit codes ≥2 rather than grep for cosmetic messages.

---

### F-026 — Bootloader installation duplicated; dead variable in shared module 🟢

- **Severity:** Low
- **Status:** open
- **File:** `scripts/build-disk-image-alpine.sh`, `shared/bootloader-install.sh`

**Description:** The Alpine disk script re-implements systemd-boot ESP installation
inline (standalone path) instead of sharing logic with `shared/bootloader-install.sh`
(host path) — two copies to keep in sync. The shared module also computes
`KERNEL_VER` and never uses it.

**Suggested fix:** Extract one implementation usable in both contexts; delete the dead
variable.

---

### F-027 — Orchestrator compresses the first matching image, not necessarily the one just built 🟢

- **Severity:** Low
- **Status:** open
- **File:** `scripts/build-iso-ubuntu.sh` (Phase 3)

**Description:** `IMG=$(ls -1 /workspace/out/playos-gpt-*.img | head -1)` — if a stale
uncompressed image from a previous (possibly other-variant) build sits in `out/`, it
gets compressed and bundled instead of the current one. The disk image path is known
exactly (`$DISK_IMG`); use it.

---

### F-028 — Three version identifiers for one Arch build root 🟢
- **Severity:** Low
- **Status:** open
- **File:** `scripts/setup-ubuntu-build-host.sh`, `arch/pacman.conf`

**Description:** The marker file records `PLAYOS_ARCH_SNAPSHOT` (2026/07/01), the
bootstrap tarball uses `PLAYOS_ARCH_BOOTSTRAP_VER` (2026.07.01), and `pacman.conf`
hardcodes the archive snapshot date in repo URLs. Changing one without the others
produces a rootfs whose marker claims a snapshot its repos don't deliver.

**Suggested fix:** Single-source the snapshot date (e.g., generate `pacman.conf` from a
template at setup time) and record all three values in `metadata.json`.

### F-029 — Persistent Arch container drifts from declared dependencies 🟡
- **Severity:** Medium
- **Status:** resolved (2026-07-29)
- **File:** `scripts/setup-ubuntu-build-host.sh`, `scripts/install-arch-build-deps.sh`

**Description:** The Arch build container (`.build/arch-rootfs`) is created once and
reused forever; `install-arch-build-deps.sh` only runs at creation time. Packages
added to the dep list later (e.g. `mtools`, needed by `build-arch-iso.sh`) are never
installed into existing containers. Observed in practice: the 2026-07-29 CachyOS
build failed with `mformat: command not found` because the container predated the
`mtools` entry.

**Suggested fix:** Re-run dep installation idempotently on each build (or hash the
dep list into the container marker so changes force a re-provision). Resolved for
this host by installing `mtools` into the existing container via pacman.

---

### F-030 — xorriso `-e` given a host path; Arch ISO could not be produced 🔴
- **Severity:** High
- **Status:** resolved (2026-07-29)
- **File:** `scripts/build-arch-iso.sh`

**Description:** The ESP FAT image was created at `$OUT_DIR/efi-boot.img` (a host
path) and passed to `xorriso -e`, which requires a path *inside* the ISO image.
Every run failed with `Cannot find path '.../out/efi-boot.img' in loaded ISO
image`, so the Arch ISO path in `build-arch-iso.sh` had never completed
successfully in this form (consistent with F-015's theme). Fixed by creating the
ESP image inside `$ISO_ROOT` and passing `-e "efi-boot.img"`.

**Suggested fix:** None remaining — fixed and proven by the successful 2026-07-29
CachyOS ISO build.

---

## Summary

| Severity | Count | IDs |
|---|---|---|
| 🔴 High | 6 | F-001, F-002, F-013, F-014, F-015, F-030 |
| 🟡 Medium | 12 | F-003, F-004, F-006, F-007, F-008, F-016, F-017, F-018, F-019, F-020, F-021, F-029 |
| 🟢 Low | 12 | F-005, F-009, F-010, F-011, F-012, F-022, F-023, F-024, F-025, F-026, F-027, F-028 |

**Open:** F-013–F-028 (second pass, 2026-07-29). All F-001–F-012 resolved; F-029/F-030 found and resolved during the 2026-07-29 CachyOS build.

---

## Recommendations (Priority Order)

These are actionable next steps derived from the findings above, ordered by impact and urgency.

### 1. ~~🔴 Investigate amdgpu firmware in initramfs (F-001)~~ ✅ DONE

Fixed: Added `lib/firmware/amdgpu/*.bin` glob to `amdgpu-firmware.files` and `lib/firmware/nvidia/*` to `nvidia-firmware.files`. Added `mkinitfs -F` flag for automatic firmware inclusion. Rewrote verification with cached decompressed listing, file counts, and dual-driver checks.

### 2. ~~🔴 Replace sed injection with a proper patch file (F-002, F-003)~~ ✅ DONE

~~Maintain a `.patch` file against the pinned aports branch (`3.24-stable`) instead of sed-patching `mkimg.base.sh` at build time.~~ Implemented: `patches/aports-mkimage.patch` + `scripts/apply-aports-patches.sh`. Patch is applied via `git apply` which fails at build time on upstream mismatch.

### 3. ~~🟡 Unify artifact naming (F-004)~~ ✅ DONE

Unified to `playos-gpt-alpine-${ALPINE_BRANCH}-${ARCH}` format. Distro prefix retained for multi-distro artifact co-existence. Both standalone and orchestrator paths use the same name.

### 4. ~~🟡 Strip ANSI from build logs (F-005)~~ ✅ DONE

Added `TERM=dumb` to all nspawn invocations in `build-iso-ubuntu.sh`. Added `--no-progress` to all `apk add` commands in both `build-disk-image-alpine.sh` and `build-alpine-iso.sh`.

### 5. ~~🟡 Implement playos-async runlevel (F-006)~~ ✅ DONE

Moved NetworkManager, iwd, and sshd from `playos-visual` to `playos-async`. Created `playos-async-trigger` init script that polls for `/run/playos-visual-ready` (written by compositor) and activates the async runlevel. Updated both ISO and disk image paths.

### 6. ~~🟡 Add firmware verification to Arch path (F-007)~~ ✅ DONE

Added firmware verification to `build-disk-image-arch.sh`: magic-byte detection (gzip/xz/lz4/zstd/cpio), decompress + grep for amdgpu entries with file count, diagnostic output on failure.

### 7. ~~🟡 Root-cause tomlplusplus ext4 segfault (F-008)~~ INVESTIGATED

Investigated: `device_profile.cpp` reads the full file into memory before parsing, so the bug is not raw I/O. Likely musl-specific. Keep the tmpfs workaround (negligible cost). File an upstream investigation issue.

### 8. ~~🟢 Fork or vendor hid-asus-ally source (F-009)~~ ✅ DOCUMENTED

Recommendation: fork `uejji/hid-asus-ally` under PlayOS-Foundation org. Existing pinned-commit workflow is correct; changing repo URL eliminates force-push risk. Alternatively, vendor source tarball at pinned commit.

### 9. ~~🟢 Document compression flow (F-010)~~ ✅ DONE

Added "Compression ownership" section to `docs/architecture/image-pipeline.md`. Orchestrator (`build-iso-ubuntu.sh`) is sole zstd owner; ISO scripts only copy pre-compressed artifact. No double-compression.

### 10. ~~🟢 Add CI validation pipeline (F-012)~~ ✅ DONE

Added `.github/workflows/ci.yml`: 4 jobs — build (Alpine disk image + ISO via nspawn), verify (GPT/filesystem checks), qemu-boot (UEFI boot + serial markers), summary. Triggers on PR, manual dispatch, and nightly. Includes amdgpu firmware warning check.

---

## Second-Pass Recommendations (2026-07-29, F-013–F-028)

Ordered by impact. Systemic themes: supply-chain verification asymmetry (Alpine
strong, Arch weak), duplication over sharing, and stateful build containers.

1. **🔴 Verify the Arch bootstrap tarball** (F-013) — fail-closed sha256/GPG check,
   mirroring the Alpine minirootfs flow.
2. **🔴 Require CachyOS signatures** (F-014) — `SigLevel = Required`, key via
   `cachyos-keyring`/WKD, hard-fail on import errors.
3. **🔴 Fix or re-scope the Arch ISO** (F-015) — it currently cannot boot an OS;
   also stop selecting ISO kernels from persistent container state.
4. **🟡 Harden Arch failure modes** (F-018, F-019) — `${VAR:?}` on UUIDs; derive
   kernel version from the target root, not the container.
5. **🟡 Close Arch service gaps** (F-021) — enable NetworkManager + sshd; port WiFi
   baking.
6. **🟡 Gate PXE deploy** (F-020) — opt-in via `PLAYOS_PXE_DEPLOY`; handle deckify
   kernel naming.
7. **🟡 Fix the clobbered EXIT trap** (F-016) — apply the documented combined-trap
   convention.
8. **🟡 Actually share `shared/`** (F-017, F-026) — fstab, device profiles, and
   bootloader install have divergent inline copies; unify or delete the dead modules.
9. **🟢 Pin remaining inputs** (F-022, F-024) — raylib sha256; record aports commit.
10. **🟢 Tighten verification tooling** (F-025, F-027) — distro-scoped artifact
    selection; exact image path for compression.

---

## Resolution Log

| Finding | Date | Status | Resolution | Verified By |
|---|---|---|---|---|
| F-001 | 2026-07-29 | resolved | Fixed mkinitfs firmware glob patterns in amdgpu-firmware.files and nvidia-firmware.files. Added mkinitfs -F flag. Improved verification with cached listing, file counts, and nvidia check. | build-disk-image-alpine.sh |
| F-002 | 2026-07-29 | resolved | Replaced sed injection with patches/aports-mkimage.patch + scripts/apply-aports-patches.sh. Patch applied via `git apply`, fails at build time on upstream mismatch. | build-alpine-iso.sh |
| F-003 | 2026-07-29 | resolved | Included in patches/aports-mkimage.patch alongside F-002. cp -Lrs → cp -rL replacement now part of version-pinned patch. | build-alpine-iso.sh |
| F-004 | 2026-07-29 | resolved | Unified naming to playos-gpt-alpine-${ALPINE_BRANCH}-${ARCH}. Distro prefix retained for multi-distro artifact co-existence. | build-disk-image-alpine.sh |
| F-005 | 2026-07-29 | resolved | Added TERM=dumb to all nspawn invocations. Added --no-progress to all apk add commands. | build-iso-ubuntu.sh |
| F-007 | 2026-07-29 | resolved | Added firmware verification to Arch build path: magic-byte detection, decompress + grep for amdgpu, with diagnostics on failure. | build-disk-image-arch.sh |
| F-006 | 2026-07-29 | resolved | Moved NetworkManager/iwd/sshd to playos-async. Created playos-async-trigger that polls for /run/playos-visual-ready and activates async runlevel. | genapkovl-playos.sh, playos-async-trigger, playos-compositor, build-disk-image-alpine.sh |
| F-008 | 2026-07-29 | investigated | device_profile.cpp reads full file into memory before parsing — not raw I/O. Likely musl-specific. Tmpfs workaround kept (~2ms). Will file upstream issue for tracking. | device_profile.cpp, playos-compositor |
| F-009 | 2026-07-29 | resolved | Documented recommendation to fork hid-asus-ally under PlayOS-Foundation org. Existing pinned-commit workflow is correct; changing repo URL eliminates force-push risk. | build-hid-asus-ally.sh |
| F-010 | 2026-07-29 | resolved | Added "Compression ownership" table to image-pipeline.md. Orchestrator is sole zstd owner; ISO scripts only copy pre-compressed artifact. No double-compression. | image-pipeline.md |
| F-012 | 2026-07-29 | resolved | Added .github/workflows/ci.yml: build + verify + qemu-boot + summary jobs. Triggers on PR, manual dispatch, and nightly. Includes amdgpu firmware check. | ci.yml |
| F-013 | 2026-07-29 | open | Arch bootstrap tarball extracted without checksum/GPG verification. | setup-ubuntu-build-host.sh |
| F-014 | 2026-07-29 | open | CachyOS repos SigLevel=Optional; GPG key via HKP with \|\| true fallbacks. Kernel unauthenticated. | arch/pacman.conf, build-disk-image-arch.sh |
| F-015 | 2026-07-29 | open | Arch ISO has no root= and standard mkinitcpio hooks — cannot boot an OS; literal ${pxe-server} in cmdline; kernel picked from persistent container /boot (deckify-first). | build-arch-iso.sh, arch/mkinitcpio.conf |
| F-016 | 2026-07-29 | open | EXIT trap clobbered: cleanup_loop replaced by initramfs-listing cleanup trap; leaks loop/mounts in standalone mode. | build-disk-image-alpine.sh |
| F-017 | 2026-07-29 | open | shared/fstab-generate.sh + shared/device-profiles.sh never sourced; inline copies drifted (profiles: rog-ally-only vs all). | shared/, build-disk-image-*.sh |
| F-018 | 2026-07-29 | open | Arch fstab writes literal PLACEHOLDER UUIDs and build succeeds when env vars missing. | build-disk-image-arch.sh |
| F-019 | 2026-07-29 | open | Arch KERNEL_VER from container /lib/modules (ls \| head -1) — stale/multi-kernel picks wrong version. | build-disk-image-arch.sh |
| F-020 | 2026-07-29 | open | PXE deploy unconditional; fails build on hosts without /var/www/html/playos + www-data; deckify kernel name unmatched. | build-iso-ubuntu.sh |
| F-021 | 2026-07-29 | open | Arch: sshd + NetworkManager installed but not enabled; PLAYOS_WIFI_* unused on Arch path. | build-disk-image-arch.sh, arch/systemd/ |
| F-022 | 2026-07-29 | open | Raylib 6.0 tarball downloaded without sha256 verification. | build-playos-components.sh |
| F-023 | 2026-07-29 | open | APK repositories hardcode v3.24, ignoring PLAYOS_ALPINE_BRANCH. | build-disk-image-alpine.sh |
| F-024 | 2026-07-29 | open | aports branch-pinned (3.24-stable), not commit-pinned; resolved commit not recorded. | build-alpine-iso.sh |
| F-025 | 2026-07-29 | open | verify-build.sh: mixed-distro out/ ambiguity; inverted vfat heuristic fails clean ESPs. | verify-build.sh |
| F-026 | 2026-07-29 | open | Bootloader install duplicated inline in Alpine disk script; dead KERNEL_VER in shared module. | build-disk-image-alpine.sh, shared/bootloader-install.sh |
| F-027 | 2026-07-29 | open | Orchestrator compresses ls \| head -1 image instead of exact $DISK_IMG path. | build-iso-ubuntu.sh |
| F-028 | 2026-07-29 | open | Three version identifiers for Arch rootfs (SNAPSHOT_DATE, BOOTSTRAP_VER, pacman.conf snapshot) can drift. | setup-ubuntu-build-host.sh, arch/pacman.conf |
| F-029 | 2026-07-29 | resolved | Persistent Arch container never re-installs deps; mtools missing broke ISO build. Fixed: mtools installed into container; suggest idempotent dep re-run. | setup-ubuntu-build-host.sh, install-arch-build-deps.sh |
| F-030 | 2026-07-29 | resolved | xorriso -e given host path for ESP image; Arch ISO unbuildable. Fixed: ESP image created inside ISO root, -e uses ISO-internal path; CachyOS ISO built successfully. | build-arch-iso.sh |
