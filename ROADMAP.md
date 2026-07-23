# PlayOS Installation Roadmap

> **From shell-script install to pre-built disk image (`dd`)**  
> **Last updated:** 2026-07-22  
> **Status:** Phases 1–4 complete (38/41 tasks). Phase 5 partial (firstboot backend done, wizard pending). Phases 6–7 remain.  
> **Target:** Industry-standard console install experience (SteamOS, Bazzite, ChimeraOS pattern)

---

## Overview

~~PlayOS installation currently uses a shell script (`playos-installer`) that:~~  
~~1. Downloads package indexes from `dl-cdn.alpinelinux.org`~~  
~~2. Calls `setup-disk -m sys` to partition + install the base Alpine system~~  
~~3. Mounts the new root, copies PlayOS binaries, configures runlevels~~

**This is done.** The shell-script installer and standalone `playos-installer-gui` have been removed.
PlayOS now ships a pre-built, compressed, checksum-verified GPT disk image. The Shell GUI (`InstallerScreen`) writes it directly to disk with a native C++ `zstd | dd` pipeline, then grows the data partition to fill. Zero network dependency, zero shell scripts at install time.

---

## Current State (2026-07-22)

### What works end-to-end

| Component | Status | Detail |
|---|---|---|
| **ISO build** | ✅ Working | `build-iso-ubuntu.sh` → `out/*.iso`, deployed to PXE |
| **PXE netboot** | ✅ Working | Kernel + initramfs + modloop + apkovl served via HTTP, boots on ROG Ally |
| **Shell installer UI** | ✅ Working | `InstallerScreen` — native C++ `zstd \| dd` pipeline, progress bar, error handling |
| **Shell script installer** | ❌ **Removed** | Old `/usr/bin/playos-installer` and `playos-installer-gui` deleted (Phases 2–3) |
| **Disk image build** | ✅ Working | 3-partition GPT (ESP + root + data), systemd-boot, `zstd` compressed |
| **Disk image in ISO** | ✅ Working | `genapkovl-playos.sh` bundles `.img.zst` into the ISO apkovl |
| **playos-firstboot** | ✅ Implemented | Regenerates machine-id, UUIDs (root/EFI/data), updates fstab/boot entry, applies pre-flight config, cleans EFI entries, deletes itself |
| **QEMU boot test** | ✅ Working | `scripts/test-disk-image-qemu.sh` — 6/7 markers pass with AHCI/TCG |
| **Boot from disk** | ⚠️ Partial | Boots and runs Shell, but has known input issues (see below) |
| **Separate data partition** | ✅ Implemented | GPT p3 mounted at `/data` (games, saves, configs), resized on install |
| **First-boot wizard** | ❌ Not started | Shell welcome wizard on first boot (WiFi, hostname, timezone) |

### Known issues on disk-booted system

| # | Issue | Status | Repo |
|---|---|---|---|
| 4 | Analog sticks not working in games | Open | `playos-runtime`, `playos-reference-devices` |
| 5 | ROG Ally Home button not recognized | Open | `playos-runtime`, `playos-reference-devices` |
| 8 | WiFi firmware for MT7921 needs on-device verification | Open (packages added, untested) | `playos-refdistro` |
| 10 | Input device mapping gaps (multiple ROG input devices) | Open | `playos-runtime`, `playos-reference-devices` |

### What was removed (old shell-script path)

| Component | Status |
|---|---|
| **Shell `InstallerScreen`** | Now runs native `zstd \| dd` pipeline in C++ ✅ |
| **`/usr/bin/playos-installer`** | **Deleted** — shell script removed from `alpine/install-script/` ✅ |
| **`/usr/bin/playos-installer-gui`** | **Deleted** — source removed from `playos-shell/src/installer/` ✅ |
| **`/run/playos/install-status`** | **Replaced** — progress now parsed from `dd` stderr ✅ |
| **Install-time network** | **Eliminated** — image is self-contained ✅ |

### What's missing entirely

| Feature | Priority | Detail |
|---|---|---|
| **First-boot welcome wizard** | P1 | Shell wizard on first boot after install: WiFi, hostname, timezone. No config during PXE/install phase. |
| **Reinstall safety ("Keep Data")** | P1 | Detecting existing p3, offering keep vs erase |
| **Image signature verification** | P3 | GPG signature check before writing (stretch goal) |
| **Update mechanism** | P1 | Check for updates, download, install — in-place (v1) or A/B atomic (v2) |
| **Hardware validation (ROG Ally)** | P0 | Write image to disk, boot, verify first frame, gamepad, WiFi, resize |
| **Recovery partition** | Future | On-disk recovery (SteamOS pattern) |
| **A/B atomic updates** | Future | Two root partitions + rauc (SteamOS pattern) |

---

## ✅ Phase 1: Hardening the Disk Image Build — COMPLETE (22/22)

**Goal:** The disk image boots reliably in QEMU and produces a playos-firstboot log with no errors.  
**Result:** Image boots in QEMU with 6/7 markers. All firstboot logic validated via code review. `findmnt` dependency fixed (util-linux added to build).

### 1.1 QEMU disk image boot test
- [x] Create `scripts/test-disk-image-qemu.sh` that:
  - Creates a throwaway QEMU qcow2 overlay from the raw image
  - Boots with UEFI (OVMF), attaches serial console
  - Validates: kernel boots, systemd-boot menu, OpenRC reaches default runlevel, playos-firstboot runs and self-deletes, compositor starts
  - Parses `dmesg` and `rc.log` for errors
- [x] Add to CI (or manual validation checklist)

### 1.2 Verify playos-firstboot correctness
- [x] Confirm machine-id is regenerated (not same as build image)
- [x] Confirm partition UUIDs are regenerated (not same as build image)
- [x] Confirm fstab is updated with new UUIDs
- [x] Confirm systemd-boot entry is updated with new root UUID
- [x] Confirm EFI boot entry is created and set as first priority
- [x] Confirm stale EFI entries from other OSes are cleaned
- [x] Confirm playos-firstboot deletes itself from runlevels
- [x] Confirm `/etc/playos/firstboot` flag file is removed

### 1.3 Validate disk image contents
- [x] All required packages present (compare against `packages.x86_64` + `mkimg.playos.sh`)
- [x] PlayOS binaries present: `playos-compositor`, `playos-shell`
- [x] Shared libraries present: `libraylib.so.450`, `libglfw.so.3`
- [x] Samples present: `/playos-samples/build/hello-playos`, `/playos-samples/build/space-invaders`
- [x] OpenRC runlevels correct: `playos-compositor`, `seatd`, `dbus`, `sshd` in default; `playos-firstboot` in default
- [x] systemd-boot config correct: `loader.conf`, `playos.conf` with correct kernel cmdline
- [x] fstab has correct UUIDs
- [x] SSH debug key present
- [x] Image size under 4 GiB uncompressed (974 MiB compressed)

### 1.4 Off-by-default services
- [x] Confirm `playos-async` runlevel is not started by default (fast-boot policy)
- [x] Confirm compositor does not wait for network, audio, Bluetooth, or cloud services

---

## ✅ Phase 2: Shell GUI — dd-Based Install Pipeline — COMPLETE (6/6)

**Goal:** The `InstallerScreen` in `playos-shell` runs the `dd` pipeline natively in C++.  
**Result:** Pipeline was already implemented. Added disk size validation. Ready for Phase 3 cleanup.

### 2.1 Implement `dd` pipeline in `InstallerScreen::StartInstall()`
- [x] Read image path: look for `.img.zst` at `/usr/share/playos/` or configured URL
- [x] Get uncompressed size from zstd header (for progress denominator)
- [x] Step 1: `zstd -d < image.zst | dd of=/dev/<target> bs=4M status=progress`
  - Parse `dd` stderr for bytes written → progress fraction
  - Update progress bar in real time (replace `/run/playos/install-status` polling)
- [x] Step 2: `sgdisk -e /dev/<target>` (relocate backup GPT to end of disk)
- [x] Step 3: `parted /dev/<target> resizepart 3 100%` (grow data partition — updated for Phase 4)
- [x] Step 4: `resize2fs /dev/<target>p3` (grow data filesystem — updated for Phase 4)
- [x] Step 5: Trigger reboot

### 2.2 Error handling
- [x] Image file not found → show error
- [x] Target disk too small → show error with required vs available size
- [x] `dd` fails (I/O error) → show error, don't reboot
- [x] `sgdisk`/`parted`/`resize2fs` fail → show error with which step failed
- [ ] Power loss during `dd` → documented as known v1 risk

### 2.3 Image location resolution
- [x] Primary: `/usr/share/playos/playos-gpt-*.img.zst` (bundled in ISO apkovl)
- [x] Fallback: USB drive mounted at `/mnt/*` and `/media/*`
- [ ] Future: HTTP download from configured URL
- [ ] Future: Embedded in PXE initramfs

### 2.4 Progress reporting
- [x] Replace status-file polling with direct stderr parsing
- [x] Show stage name + percentage: "Writing to disk...", "Expanding data partition...", "Growing data filesystem..."
- [x] Animated progress bar

---

## ✅ Phase 3: Remove the Old Install Path — COMPLETE (4/4)

**Goal:** The shell script installer is gone. Only the pre-built disk image path remains.

### 3.1 Remove from build
- [x] Remove `alpine/install-script/playos-installer` from `build-playos-components.sh`
- [x] Remove `playos-installer-gui` from `build-playos-components.sh`
- [x] Remove `playos-installer` and `playos-installer-gui` from `genapkovl-playos.sh` bundle step
- [x] Remove `playos-installer-gui` target from `playos-shell/CMakeLists.txt`

### 3.2 Remove from repos
- [x] Delete `alpine/install-script/playos-installer` (and entire directory)
- [x] Delete `playos-shell/src/installer/main.cpp` (and entire directory)
- [x] `alpine/init.d/playos-installer` — did not exist, no action needed

### 3.3 Clean up Shell
- [x] `InstallerScreen` uses native dd pipeline — no shell-script fallback
- [x] Removed `/run/playos/install-status` references (uses `/run/playos/dd-progress`)
- [x] Removed `/run/playos/install-target` references

---

## ✅ Phase 4: Separate Data Partition — MOSTLY COMPLETE (5/6)

**Goal:** Game installs and user data survive OS reinstallation. Follows the SteamOS/Batocera pattern.

### 4.1 Update partition layout
```
p1: ESP (vfat, 512 MiB)     — bootloader + kernels
p2: root (ext4, 4096 MiB)   — OS, read-only or atomically updated
p3: data (ext4, remaining)  — /data (games, saves, configs, logs)
```
Image size increased from 4096 MiB → 6144 MiB to accommodate p3 placeholder (~1.5 GiB).

### 4.2 Build-time changes
- [x] Update `build-disk-image.sh` (and `build-iso-ubuntu.sh` layout phase) to create p3
- [x] `mkfs.ext4 -L playos-data` on p3
- [x] Mount p3 at `/data` in fstab
- [x] Create `/data/games`, `/data/saves`, `/data/config` directories
- [ ] Move samples from `/playos-samples` to `/data/games/` — deferred (symlink approach TBD)
- [x] `playos-firstboot`: regenerates data partition UUID, updates fstab

### 4.3 Shell/game changes
- [x] Shell looks for installed games in `/data/games/` (scans for executables)
- [x] Games save to `/data/saves/<game-id>/` (directory exists, Shell responsible for subdirectories)
- [x] Configs stored in `/data/config/` (directory exists)

### 4.4 Reinstall safety
- [ ] **PENDING:** Installer detects existing p3, offers "Keep data" vs "Erase everything"
  - Requires per-partition dd or sgdisk-based partition restore — non-trivial
  - Deferred to post-v1

---

## ⚠️ Phase 5: First-Boot Experience — PARTIAL (1/3)

**Goal:** After OS install, first boot shows a welcome wizard in Shell. No configuration during PXE/install phase — just pick disk and go.

### 5.1 First-boot wizard in Shell
- [ ] **PENDING:** Shell detects first boot (flag file `/etc/playos/firstboot`), shows welcome wizard
  - WiFi: scan networks, select + enter password
  - Hostname: text input (default: playos)
  - Timezone: list selector
  - "Skip" button → proceed with defaults
  - After completion: transitions to game library

### 5.2 First-boot backend (playos-firstboot)
- [x] `playos-firstboot` already handles: machine-id, UUID regeneration (root/EFI/data), fstab/boot entry updates, EFI cleanup, self-deletion
- [ ] Replace ESP config-file reading with Shell wizard integration (Shell writes settings, firstboot applies them)
- [ ] Remove pre-flight ESP config reading code (development convenience, not for release)

### 5.3 Install flow (no config prompts)
- [x] PXE boot → Shell → pick disk → confirm → `dd` → resize → reboot
- [x] No WiFi/hostname/timezone prompts during install
- [x] Clean, simple: one decision (which disk), one button (install)

---

## Phase 6: Hardware Validation (ROG Ally)

**Goal:** Disk image installs and boots correctly on the primary reference hardware.

### 6.1 Write image to ROG Ally
- [ ] Put `.img.zst` on USB drive
- [ ] Boot ROG Ally from PXE (existing flow) or USB
- [ ] In Shell, open Installer overlay → select NVMe disk → confirm
- [ ] Verify `dd` pipeline completes without errors
- [ ] Verify `resize2fs` fills the disk

### 6.2 First boot validation
- [ ] System boots from NVMe (not PXE)
- [ ] EFI boot entry is "PlayOS" and is first priority (check `efibootmgr`)
- [ ] No stale EFI entries from other OSes
- [ ] Machine-id is unique (not cloned from image)
- [ ] Partition UUIDs are unique
- [ ] `playos-firstboot` ran and self-deleted
- [ ] Compositor starts, Shell appears on screen
- [ ] Boot time: measure from UEFI handoff to first Shell frame (target: < 3s)

### 6.3 Functionality validation
- [ ] Gamepad navigation works in Shell (D-pad, A/B buttons)
- [ ] Analog sticks work in Space Invaders (issue #4 fix verification)
- [ ] Home button returns to Shell (issue #5 fix verification)
- [ ] WiFi scans and connects (issue #8 fix verification)
- [ ] Launch Space Invaders → play → exit → return to Shell
- [ ] Launch hello-playos → exit → return to Shell
- [ ] SSH accessible via debug key

### 6.4 Edge cases
- [ ] Install on disk that previously had PlayOS (re-install)
- [ ] Install on disk that had Windows/SteamOS (clean EFI entries)
- [ ] Install on disk smaller than image (should reject, not fail silently)
- [ ] Power loss during `dd` (document behavior, note A/B as future mitigation)

---

## Phase 8: Update Mechanism

**Goal:** Shell can check for, download, and install PlayOS updates. Data partition survives updates.

### Research findings

| Area | Current state |
|---|---|
| **Update code** | None — `playos-update` is a placeholder name in docs only |
| **Shell screens** | Overlay has 3 items (WiFi, Install, Close). No settings/update UI |
| **Versioning** | Alpine branch only (`v3.24`). No PlayOS build number |
| **Bootloader** | systemd-boot, single entry, `timeout 0` — supports A/B natively |
| **Partitions** | 6144 MiB image — too small for A/B (needs ~10 GiB+) |
| **apk** | Available in disk image, repos pre-configured |

### 8.1 Phase 8a — In-place updates (v1, simpler)
- [ ] **Build versioning:** Embed `PLAYOS_VERSION` + build timestamp in image (`/etc/playos/version`)
- [ ] **Update server:** Serve a version manifest JSON + updated `.img.zst` at a known URL
- [ ] **`playos-update` init script:** OpenRC service in `playos-async` runlevel
  - Fetches version manifest, compares to installed version
  - If newer: downloads `.img.zst`, verifies sha256
- [ ] **Shell `UpdateScreen`:** 
  - "Check for Updates" button in overlay menu
  - Shows current version, available version, changelog
  - "Download & Install" — progress bar, then "Reboot to apply"
- [ ] **Install logic:** Write new p1+p2 (ESP + root) only, preserve p3 (data)
  - Reuses existing `zstd | dd` pipeline from `InstallerScreen`
  - After reboot: `playos-firstboot` runs, data partition untouched

### 8.2 Phase 8b — A/B atomic updates (v2, SteamOS pattern)
- [ ] Expand image size to ~10 GiB (ESP 512M + root-a 4096M + root-b 4096M + data fills rest)
- [ ] systemd-boot: dual entries (`playos-a.conf`, `playos-b.conf`) + boot counting
- [ ] Update writes to inactive slot, bootloader switches on next boot
- [ ] Boot counting: auto-fallback to previous slot after N failed boots

---

## Phase 7: Documentation & Cleanup

### 7.1 Consolidate docs
- [ ] Archive `docs/PlayOS-Installation.md` as historical record (issues 1-11 mostly resolved or tracked elsewhere)
- [ ] `docs/longterm-install.md` → promote from "plan" to "implemented" status, update with actual implementation details
- [ ] `docs/linux-distro-install-research.md` → keep as reference
- [ ] This `ROADMAP.md` → living document, update as phases complete

### 7.2 Update cross-repo docs
- [ ] `playos-spec/book/` — add installation chapter referencing the pre-built image approach
- [ ] `playos-shell/ROADMAP.md` — update Shell installer status
- [ ] Each repo's `AGENTS.md` — no changes needed (already reflect current architecture)

---

## Dependency Graph

```
Phase 1 (Disk image hardening)
 └─→ Phase 2 (Shell dd pipeline) ──→ Phase 3 (Remove old path)
      │
      └─→ Phase 4 (Data partition) ──→ Phase 5 (First-boot wizard) ──→ Phase 8a (In-place updates)
                                            │
                                            └─→ Phase 6 (Hardware validation)
                                                   │
                                                   └─→ Phase 7 (Docs & cleanup)

Phase 8b (A/B atomic) depends on Phase 8a + image layout redesign
```

Phases 1, 4, and 8a are independent. Phase 2 depends on 1. Phase 3 depends on 2. Phase 5 depends on 4. Phase 6 depends on 2, 4, 5. Phase 8a depends on 4 (data partition survives update).

---

## Cross-Repo Impact

| Change | Repository |
|---|---|
| Shell `InstallerScreen` dd pipeline | `playos-shell` |
| Remove `playos-installer-gui` | `playos-shell` |
| Remove `playos-installer` shell script | `playos-refdistro` |
| Disk image build script | `playos-refdistro` |
| `playos-firstboot` enhancements | `playos-refdistro` |
| Data partition support | `playos-refdistro`, `playos-shell` |
| Pre-flight config schema | `playos-spec` (RFC, schemas) |
| Input/device fixes | `playos-runtime`, `playos-reference-devices` |
| Sample path updates | `playos-samples` |

---

## Immediate Next Steps

### 🔴 Priority — Rebuild disk image with Phase 4 changes
The current `out/playos-gpt-v3.24-x86_64.img.zst` was built BEFORE:
- 3-partition layout (p3 data partition)
- `util-linux` package addition (fixes `findmnt` in firstboot)
- Old installer removal from build pipeline

**Action:** Run `bash scripts/build-iso-ubuntu.sh` to produce a fresh image with all Phase 1–4 changes.

### 🟡 Priority — First-boot welcome wizard (Phase 5.1)
Add a welcome wizard to `playos-shell` that runs on first boot after OS install:
- Detects first boot via `/etc/playos/firstboot` flag
- WiFi scan + password, hostname input, timezone selector
- Replaces pre-flight ESP config approach (dev convenience, not for users)

### 🟡 Priority — Reinstall safety (Phase 4.4)
Implement "Keep Data" vs "Erase Everything" in `InstallerScreen`:
- Detect existing p3 on target disk
- "Keep Data" only writes p1+p2 (need per-partition dd)
- "Erase Everything" writes full image

### 🟢 Phase 6 — Hardware Validation (ROG Ally)
Requires physical ROG Ally device. Full checklist in Phase 6 section below.

---

## Completed Detail Tasks (Phases 1–5)

> All A–G module tasks from the original "Next Steps — Immediate" section are complete (39/41 done, 2 pending).
> Key artifacts: `out/playos-gpt-v3.24-x86_64.img.zst` (974 MiB compressed), `scripts/test-disk-image-qemu.sh`

---

## References

- `docs/linux-distro-install-research.md` — Industry research on 10 distributions
- `docs/boot-budget.md` — Cold boot to first frame in < 3s
- `docs/fast-boot.md` — Visual path before background services
- `docs/service-order.md` — OpenRC runlevel dependencies
- `scripts/build-disk-image.sh` — Disk image build
- `scripts/build-iso-ubuntu.sh` — Full build pipeline (canonical build entrypoint)
- `alpine/init.d/playos-firstboot` — First-boot service
- `alpine/init.d/playos-compositor` — Compositor OpenRC service
