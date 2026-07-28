# Roadmap

## Current baseline

- Alpine `v3.24` image tooling produces a compressed GPT disk image and a
  bootable ISO.
- Ubuntu uses a pinned Alpine minirootfs through `systemd-nspawn`.
- The build compiles sibling PlayOS components against musl and bundles the
  compositor, Shell, and samples.
- The disk image uses systemd-boot, a separate data partition, and one-shot
  first-boot initialization.

## Arch Linux + CachyOS backend ✅ (complete)

Two Arch Linux ISO variants now build alongside the existing Alpine pipeline
using CachyOS optimized kernels:

- **MinArch** (`linux-cachyos`): EEVDF scheduler, Clang ThinLTO, AutoFDO PGO —
  optimal for general devices.
- **MinArch Handheld** (`linux-cachyos-deckify`): BORE scheduler, handheld
  patches (ROG Ally, Steam Deck, MSI Claw, Legion Go drivers), plus `asusctl`
  for TDP/fan/GPU control.

See `feat/arch-distro-backend` branch. Commits: `fec08a5`.

```bash
# General variant
PLAYOS_DISTRO=arch PLAYOS_KERNEL_VARIANT=cachyos bash scripts/build-iso-ubuntu.sh

# Handheld variant
PLAYOS_DISTRO=arch PLAYOS_KERNEL_VARIANT=deckify bash scripts/build-iso-ubuntu.sh
```

Both produce: `playos-gpt-arch-{variant}-x86_64.img.zst` + `playos-arch-{variant}-x86_64.iso`.

Architecture: shared code extracted from Alpine scripts into `shared/`,
Arch-specific config in `arch/` (pacman.conf with pinned archive + CachyOS znver4
repos, systemd units, mkinitcpio.conf), disk population via `pacman -r`, initramfs
via mkinitcpio, bootloader via systemd-boot.

## Next milestones

1. **Migrate Raylib to 6.0 via custom APKBUILD.** Alpine 3.24 ships raylib
   5.0-r0 only. Create a custom `alpine/apkbuilds/raylib/APKBUILD` for 6.0,
   update soname references (`libraylib.so.450` → `libraylib.so.600`) in
   `genapkovl-playos.sh`, `build-disk-image.sh`, and `playos-installer`,
   then integrate the custom repo into `build-playos-components.sh`. Also
   update `playos-shell/gen-context.md` and `playos-spec` book chapter for
   the new version. See `mig2raylib6.md` for the full plan.
2. Build the existing ISO and disk image, then validate the artifacts and boot
   path in QEMU.
3. Record reproducible build inputs and validation evidence for that baseline
   image.
4. Complete ROG Ally hardware testing only after QEMU validation passes for
   device-facing changes. See [ROG Ally driver integration](#rog-ally-driver-integration)
   below for the kernel and controller driver work that feeds into this milestone.
5. Move non-visual services to a readiness-triggered `playos-async` path so
   networking, SSH, audio, Bluetooth, and background features cannot affect
   first-frame latency.
6. Replace direct binary copying with signed PlayOS APK packages built from
   pinned sources.

## ROG Ally driver integration

ROG Ally hardware has specific kernel driver needs beyond what the base Alpine
image provides. A comprehensive driver survey is in
[`ROG-LinuxDriverSupport.md`](ROG-LinuxDriverSupport.md); hardware findings
that drive these priorities are in
[`docs/hardware/rog-ally.md`](docs/hardware/rog-ally.md).

### Phase 1: Switch `linux-lts` → `linux-stable` ✅ (complete)

Alpine v3.24 community ships `linux-stable 7.1.4`, which includes the
`asus-armoury` platform driver (mainlined in 6.19). This gives us advanced
TDP controls (core count, APU memory, dGPU TGP) without a custom kernel build.

**Completed:**
- `alpine/mkimg.playos.sh`: `kernel_flavors="stable"`, `kernel_addons=""`
- `scripts/build-disk-image.sh`: `linux-stable` apk + all boot paths → `-stable`
- `scripts/build-iso-ubuntu.sh`: all `-lts` → `-stable` paths
- `alpine/boot.ipxe`, `alpine/boot-debug.ipxe`: kernel paths → `-stable`
- `scripts/verify-build.sh`: expected filenames → `-stable`
- `xtables-addons`: cleared `kernel_addons=""` (no `-stable` variant in Alpine)
- QEMU boot test: 7/7 boot markers passed on `linux-stable 7.1.4`
- ROG Ally hardware boot: confirmed kernel 7.1.4-0-stable

See commits on `feat/kernel-stable-rog-ally`: `b1e5a82`–`deb0b61`.

### Phase 2: `hid-asus-ally` kernel module ✅ (complete)

The ROG Ally controller needs a device-specific HID driver for back
paddles (M1/M2), gyroscope, ROG Crate, and Command Center buttons.

**Completed:**
- `scripts/build-hid-asus-ally.sh`: builds `.ko` against `linux-stable-dev`
- Integrated into `build-playos-components.sh` (nspawn build)
- `.ko` installed directly into rootfs modules tree (bypassed APK signing)
- Confirmed in rootfs: `/lib/modules/7.1.4-0-stable/kernel/drivers/hid/hid-asus-ally.ko` (1.1 MB)
- QEMU boot test: 7/7 boot markers passed
- ROG Ally hardware: module present in installed system

See commits on `feat/kernel-stable-rog-ally`: `deb0b61`–`7dd3449`.

### Phase 2.5: Installer bug fixes ✅ (complete)

Three bugs found and fixed during ROG Ally hardware testing:

| Bug | Root Cause | Fix | Repo |
|---|---|---|---|
| Data fs fail after dd | Filesystem dirty flag blocks `resize2fs` | `e2fsck -f -y` before `resize2fs` in Shell installer | playos-shell |
| Data partition 1.5G after install | Filesystem size copied from 6GB image | `resize2fs` in `playos-firstboot` | playos-refdistro |
| WiFi retry fails after wrong pw | NM keeps stale failed profile | Delete NM profile before each connect attempt | playos-platform-api |

### Phase 3: Raylib 5.0 → 6.0 migration ⬅️ IN PROGRESS

Build Raylib 6.0 from source (instead of Alpine's 5.0 package), update soname
references from `libraylib.so.450` → `libraylib.so.600`. See [`mig2raylib6.md`](mig2raylib6.md)
for the implementation details. Approach: direct cmake+ninja source build in
`build-playos-components.sh` (skipped APKBUILD to avoid signing complexity).

### Phase 4: Build + QEMU validation

```bash
bash scripts/build-iso-ubuntu.sh         # Full pipeline (image + ISO + PXE)
bash scripts/verify-build.sh              # Artifact integrity checks
bash scripts/test-disk-image-qemu.sh      # Disk image boot test
bash scripts/test-iso-qemu.sh             # ISO boot test
```

### Dependency order

```
Phase 1 (kernel switch) ✅ ──→ Phase 2 (hid-asus-ally) ✅
                                        │
Phase 3 (raylib 6.0) ⬅️ NEXT ──────────┤
                                        │
                                        └──→ Phase 4 (validate)
```

Phase 1 must complete first — Phase 2 builds against the new kernel headers.
Phase 3 is independent and can run in parallel.

## Documentation

The current build, image, boot, and validation model is documented in
[`docs/README.md`](docs/README.md).
