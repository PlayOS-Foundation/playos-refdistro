# Audit Findings — playos-refdistro

> **Date:** 2026-07-29
> **Scope:** Full repository audit: build pipeline, ISO creation, disk image, init systems, services, documentation
> **Method:** Line-by-line review of all scripts, configs, init files, shared libraries, docs, and latest build log

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

## Summary

| Severity | Count | IDs |
|---|---|---|
| 🔴 High | 2 | F-001, F-002 |
| 🟡 Medium | 5 | F-003, F-004, F-006, F-007, F-008 |
| 🟢 Low | 5 | F-005, F-009, F-010, F-011, F-012 |

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
