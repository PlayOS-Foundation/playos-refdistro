# Long-Term Install: Pre-built Disk Image

> **Status:** Plan — not yet implemented  
> **Goal:** Eliminate runtime shell-script orchestration during disk installation.  
> **Approach:** Pre-build a complete GPT-partitioned raw disk image; the GUI streams it to disk with `dd`.

---

## 1. Motivation

The current install flow (v0.2) requires a 150-line shell script (`playos-installer`) to run at install time. This script:

- Calls `apk update` to fetch package indexes over the network
- Calls `setup-disk -m sys` to partition and install the base Alpine system
- Mounts the new root and copies PlayOS custom binaries, libraries, and services
- Configures OpenRC runlevels, cleans EFI boot entries

**Problems this creates:**

| Issue | Impact |
|---|---|
| Network dependency at install time | Install fails without connectivity to `dl-cdn.alpinelinux.org` |
| `setup-disk` churn risk | Alpine's disk tool may change behavior across releases |
| Shell script maintenance | Partition naming logic (NVMe/SATA/eMMC), error handling, edge cases |
| Status-file polling | GUI parses a text file for progress — fragile and slow to react |
| No image verification | No checksum or signature check on what gets installed |
| Slow install | Downloads packages, runs `setup-disk`, copies binaries — several minutes |

**Industry standard:** SteamOS, Bazzite, ChimeraOS, Ubuntu Core, Raspberry Pi OS, and Fedora IoT all ship pre-built disk images. The GUI streams them to disk with a progress bar. No shell scripts, no package downloads, no partitioning logic at runtime.

---

## 2. Proposed Architecture

### 2.1 Build Time (CI / developer workstation)

```
playos-refdistro build pipeline
  ├── Builds all PlayOS components (compositor, shell, samples) [unchanged]
  ├── Builds Alpine base system in a chroot                 [unchanged]
  ├── Creates a raw GPT disk image with:
  │     ├── Partition 1: EFI System Partition (vfat, 512 MiB)
  │     │     └── systemd-boot or grub EFI binary
  │     └── Partition 2: Root filesystem (ext4, ~3 GiB min)
  │           └── Full PlayOS system (all packages + binaries)
  ├── Compresses image: `playos-gpt-3.24.0-x86_64.img.zst`
  ├── Computes SHA-256: `playos-gpt-3.24.0-x86_64.img.zst.sha256`
  └── Signs image: `playos-gpt-3.24.0-x86_64.img.zst.sig`
```

### 2.2 Install Time (GUI on device)

```
User presses "Install to Disk" in Shell overlay
  → InstallerScreen opens (unchanged UI flow)
  → User confirms
  → GUI executes (from C++, no shell scripts):
      1. Verify image signature (optional, requires embedded pubkey)
      2. zstd -d < image.zst | dd of=/dev/nvme0n1 bs=4M status=progress
         → Parse dd stderr for bytes-written / total-bytes → progress bar
      3. sgdisk -e /dev/nvme0n1              (relocate backup GPT to end of disk)
      4. parted /dev/nvme0n1 resizepart 2 100%  (grow root partition to fill disk)
      5. resize2fs /dev/nvme0n1p2             (grow filesystem)
      6. Reboot
```

**This eliminates ALL shell scripts from the install path.** The GUI calls individual tools (`dd`, `sgdisk`, `parted`, `resize2fs`) via `fork()`/`exec()` with progress reported natively in C++.

### 2.3 First Boot (after install)

The installed system boots from the newly written disk. It runs a one-shot OpenRC service (`playos-firstboot`) that:

1. Regenerates `/etc/machine-id` (systemd's tool or `uuidgen`)
2. Regenerates partition UUIDs if needed (`tune2fs -U random`, `fatlabel`)
3. Runs `efibootmgr` to create a clean EFI boot entry pointing to itself
4. Deletes itself from runlevels (one-shot)
5. Triggers normal boot

---

## 3. Partition Layout

```
/dev/nvme0n1 (or sda, mmcblk0)
├── Partition 1: EFI System Partition
│     Type: C12A7328-F81F-11D2-BA4B-00A0C93EC93B (ESP)
│     Size: 512 MiB (fixed in image, resized during first-boot if needed)
│     FS:   vfat
│     Mount: /boot/efi
│     Contents: systemd-boot EFI binary, kernel, initramfs
│
├── Partition 2: Root filesystem
│     Type: 0FC63DAF-8483-4772-8E79-3D69D8477DE4 (Linux root x86-64)
│     Size: ~3 GiB in image → resized to fill remaining disk at install time
│     FS:   ext4
│     Mount: /
│     Contents: Full PlayOS system (all apk packages + custom binaries)
│
└── Free space after partition 2: 0 bytes (filled by resize)
```

**Why not btrfs?** ext4 is simpler, faster to resize, and has no copy-on-write overhead. If PlayOS later needs snapshots for A/B updates, btrfs can be added as a separate partition or the layout can be revisited. SteamOS uses btrfs for root; PlayOS can follow if needed.

---

## 4. Build-Time Implementation

### 4.1 New Script: `scripts/build-disk-image.sh`

This script produces the raw GPT image during the build pipeline. It runs after `build-playos-components.sh` and before (or instead of) `mkimage.sh`.

```bash
#!/usr/bin/env bash
# build-disk-image.sh — Produce a raw GPT disk image for dd-based installation.
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
OUT="$ROOT/out"
IMAGE_SIZE_MB="${PLAYOS_IMAGE_SIZE_MB:-4096}"  # 4 GiB min, expandable
IMAGE_NAME="playos-gpt-${PLAYOS_ALPINE_BRANCH:-3.24}-${PLAYOS_ARCH:-x86_64}"

# 1. Create a sparse raw image file
truncate -s "${IMAGE_SIZE_MB}M" "$OUT/$IMAGE_NAME.img"

# 2. Partition with sgdisk (non-interactive GPT)
sgdisk -Z "$OUT/$IMAGE_NAME.img"                          # zap existing
sgdisk -n 1:1M:+512M -t 1:EF00 "$OUT/$IMAGE_NAME.img"     # ESP, 512 MiB
sgdisk -n 2:0:0     -t 2:8300 "$OUT/$IMAGE_NAME.img"      # Linux root, rest of image

# 3. Mount image via loop device
LOOP=$(losetup --find --show -P "$OUT/$IMAGE_NAME.img")

# 4. Format partitions
mkfs.vfat -F32 "${LOOP}p1"
mkfs.ext4 -F "${LOOP}p2"

# 5. Mount partitions
mkdir -p /mnt/playos-image-root /mnt/playos-image-esp
mount "${LOOP}p2" /mnt/playos-image-root
mkdir -p /mnt/playos-image-root/boot/efi
mount "${LOOP}p1" /mnt/playos-image-root/boot/efi

# 6. Install Alpine base + PlayOS packages into the mounted root
apk --root /mnt/playos-image-root --initdb add alpine-base
apk --root /mnt/playos-image-root add \
    dbus dbus-openrc seatd seatd-openrc \
    networkmanager networkmanager-openrc networkmanager-wifi wpa_supplicant \
    wayland wlroots0.19 mesa-dri-gallium mesa-vulkan-ati \
    linux-lts linux-firmware-amdgpu \
    raylib glfw \
    openssh bluez bluez-openrc pipewire wireplumber \
    eudev eudev-openrc openrc

# 7. Copy PlayOS custom binaries / services (same as genapkovl today)
install -m 0755 /usr/bin/playos-compositor   /mnt/playos-image-root/usr/bin/
install -m 0755 /usr/bin/playos-shell        /mnt/playos-image-root/usr/bin/
install -m 0755 /usr/bin/playos-installer-gui /mnt/playos-image-root/usr/bin/
# ... same as current genapkovl logic

# 8. Configure OpenRC runlevels (symlinks + playos-compositor init.d)
# ... same as current genapkovl logic

# 9. Install bootloader (systemd-boot or grub to ESP)
# ...

# 10. Create /etc/playos/firstboot flag file
touch /mnt/playos-image-root/etc/playos/firstboot

# 11. Unmount and clean up
umount /mnt/playos-image-root/boot/efi
umount /mnt/playos-image-root
losetup -d "$LOOP"

# 12. Compress
zstd -T0 --rm -12 "$OUT/$IMAGE_NAME.img"

# 13. Checksum
sha256sum "$OUT/$IMAGE_NAME.img.zst" > "$OUT/$IMAGE_NAME.img.zst.sha256"

echo "Disk image written to $OUT/$IMAGE_NAME.img.zst"
```

### 4.2 Integration into Build Pipeline

The disk image becomes a **peer artifact** to the ISO — not a replacement:

```
build-iso-ubuntu.sh (or build-iso-docker.sh)
  ├── nspawn / Docker → build-playos-components.sh     [unchanged]
  ├── nspawn / Docker → build-alpine-iso.sh            [unchanged, ISO for PXE/netboot dev]
  └── nspawn / Docker → build-disk-image.sh            [NEW: disk image for dd install]
```

**Rationale for keeping the ISO:**
- PXE/netboot is essential for development iteration (no need to write disk each time)
- QEMU testing uses the ISO
- The ISO remains the "zero-touch" bring-up path

### 4.3 Build Dependencies

New host dependencies on the build server:
- `sgdisk` (gptfdisk) — already in current dep list
- `zstd` — likely already present
- `parted` — for the resize step (at install time, not build time)
- No new Alpine packages needed inside nspawn

---

## 5. Install-Time Implementation (GUI Changes)

### 5.1 Changes to `playos-shell/src/screens/installer_screen.cpp`

The installer screen changes from:
```cpp
// OLD: Spawn shell script, poll status file
std::system("/usr/bin/playos-installer &");
ReadStatus(m_statusStage, m_statusPercent, m_statusError);
```

To:
```cpp
// NEW: Run dd + resize pipeline, parse stderr for progress
void InstallerScreen::StartInstall() {
    m_installing = true;
    m_totalBytes = GetImageSize();  // Read .zst uncompressed size

    // Step 1: Decompress + write
    // zstd -d < image.zst | dd of=/dev/nvme0n1 bs=4M
    // Pipe stdout to dd, capture dd stderr for progress (USR1 signal or status=progress)

    // Step 2: Relocate backup GPT
    // sgdisk -e /dev/nvme0n1

    // Step 3: Resize partition 2
    // parted /dev/nvme0n1 resizepart 2 100%

    // Step 4: Resize filesystem
    // resize2fs /dev/nvme0n1p2

    // Step 5: Reboot
}
```

### 5.2 Progress Reporting

Instead of polling a status file, the GUI reads `dd` stderr directly:

```cpp
// dd with status=progress writes to stderr:
// "4294967296 bytes (4.3 GB, 4.0 GiB) copied, 12.3 s, 349 MB/s"
// Parse: bytes_copied / total_bytes → progress fraction
```

This is more responsive and eliminates the `/run/playos/install-status` IPC file entirely.

### 5.3 Image Location

The raw disk image is:
- **Pre-loaded** on the recovery/PXE partition (if one exists)
- Or **fetched from USB** during offline install
- Or **fetched from network** during online install (same HTTP server used for PXE today)
- Or **embedded in the PXE initramfs** (large but self-contained)

For the ROG Ally, the image lives on a USB drive plugged into the device. The GUI can also download it from a configured URL.

---

## 6. First-Boot Service

### 6.1 New OpenRC Service: `playos-firstboot`

```
/etc/init.d/playos-firstboot
/etc/runlevels/default/playos-firstboot  (enabled at build time)
```

The service runs once on first boot after the image is written to disk:

```sh
#!/bin/sh
# playos-firstboot — One-shot first-boot setup for dd-installed images.

description="PlayOS first-boot setup"

depend() {
    need localmount
    after bootmisc
}

start() {
    ebegin "Running PlayOS first-boot setup"

    # 1. Regenerate machine-id
    uuidgen > /etc/machine-id 2>/dev/null || true

    # 2. Regenerate partition UUIDs (so clones don't collide)
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    tune2fs -U random "$ROOT_DEV" 2>/dev/null || true

    # 3. Create EFI boot entry
    if [ -d /sys/firmware/efi ]; then
        efibootmgr --create --disk "$(root_disk)" --part 1 \
            --label "PlayOS" --loader /vmlinuz-lts \
            --unicode "root=PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_DEV") ro quiet"
    fi

    # 4. Remove ourselves from runlevels
    rm -f /etc/runlevels/default/playos-firstboot
    rm -f /etc/playos/firstboot

    eend 0
}

root_disk() {
    # Return the disk device (not partition) for the root filesystem
    local root_dev=$(findmnt -n -o SOURCE /)
    echo "$root_dev" | sed 's/[0-9]*$//'
}
```

---

## 7. Implementation Phases

### Phase 1: Build the disk image (2-3 days)

- [ ] Create `scripts/build-disk-image.sh`
- [ ] Integrate into `build-iso-ubuntu.sh` (parallel artifact, not replacement)
- [ ] Test: produce a compressing, mountable, bootable image
- [ ] Test: boot the raw image in QEMU (direct kernel boot from the raw image)
- [ ] Validate: `sha256sum` and size

### Phase 2: First-boot service (1 day)

- [ ] Create `playos-firstboot` init script
- [ ] Create `/etc/playos/firstboot` flag file in image build
- [ ] Test: write image to a virtual disk, boot in QEMU, verify UUIDs regenerated

### Phase 3: GUI dd pipeline (2-3 days)

- [ ] Rewrite `InstallerScreen::StartInstall()` to run dd pipeline
- [ ] Implement `dd` stderr parsing for progress
- [ ] Add image signature verification (optional stretch goal)
- [ ] Remove deprecated `installer_screen.cpp` approach with shell script

### Phase 4: Remove old install script (1 day)

- [ ] Remove `alpine/install-script/playos-installer`
- [ ] Remove `playos-installer` from `build-playos-components.sh`
- [ ] Remove `playos-installer-gui` from build
- [ ] Update `genapkovl-playos.sh` to exclude installer binaries
- [ ] Update ROADMAP.md and AGENTS.md

### Phase 5: Hardware validation (2-3 days)

- [ ] Write image to USB, boot ROG Ally from USB
- [ ] Run installer from Shell overlay
- [ ] Verify first boot: compositor starts, shell shows library
- [ ] Verify `resize2fs` fills the disk
- [ ] Verify EFI boot entry is clean (no stale entries)
- [ ] Verify install survives power loss during `dd`? (not for v1, but document)

---

## 8. Trade-offs and Decisions

### 8.1 Image size vs. build complexity

| Approach | Image size | Complexity |
|---|---|---|
| **Full pre-built image** (proposed) | ~1-2 GiB compressed | Low runtime, medium build time |
| Minimal base image + network install | ~200 MiB compressed | High runtime (network required) |
| Current approach (ISO PXE + script) | ISO only, no disk image | High runtime (shell script) |

**Decision: Full pre-built image.** The ROG Ally has sufficient storage. A 2 GiB compressed image is manageable for USB and HTTP distribution.

### 8.2 `dd` vs `bmaptool`

`bmaptool` is faster (skips empty blocks) and provides built-in checksumming. However:
- `dd` is universally available on every Linux system
- `bmaptool` requires a block map file (`.bmap`) generated at build time
- For sparse images with mostly-filled partitions, the speed difference is minimal

**Decision: Start with `dd`; add `bmaptool` as an optimization if needed.**

### 8.3 Per-device images vs. single generic image

PlayOS targets multiple devices (ROG Ally, Steam Deck, Legion Go, Orange Pi). A single x86_64 image works for all AMD-based handhelds (same GPU driver, same kernel modules). ARM devices (Orange Pi) need separate images.

**Decision: One x86_64 image for all AMD handhelds. ARM images as separate artifacts.**

### 8.4 Bootloader: systemd-boot vs grub

| | systemd-boot | grub |
|---|---|---|
| Binary size | ~128 KiB | ~several MiB |
| Config complexity | Minimal (text files) | High (generated scripts) |
| Recovery shell | No | Yes (useful for debug) |
| UEFI-only | Yes | No (supports BIOS) |
| Alpine support | Via `systemd-boot` package | Via `grub-efi` package |

**Decision: systemd-boot for new images.** PlayOS only targets UEFI hardware (ROG Ally, Steam Deck, etc.) and systemd-boot is the standard for appliance-style images.

### 8.5 Image signing

Signing ensures the image wasn't tampered with between build and install. This requires:
- A signing key in CI
- The public key embedded in the PXE initramfs or recovery partition
- Signature verification in the GUI before `dd`

**Decision: Defer to Phase 3 as stretch goal.** Unsigned images are acceptable for v1; the current approach has no signing either.

---

## 9. Migration Path

The existing ISO + PXE + shell-script approach remains **fully supported** during development:

| Path | Use case |
|---|---|
| **ISO + PXE** (current) | Development iteration, QEMU testing |
| **Disk image + dd** (new) | Production install on hardware |

The disk image is a **superset** of the ISO — it contains everything the ISO does, just pre-installed onto a partition layout. Both artifacts are produced by the same build pipeline.

Once the disk-image path is validated on hardware, the old shell-script install path can be deprecated and removed.

---

## 10. References

- [SteamOS recovery image](https://help.steampowered.com/en/faqs/view/1B71-EDF2-EB6D-2BB3) — pre-built image, `dd` to disk
- [Bazzite installation](https://docs.bazzite.gg/General/Installation_Guide/) — `dd` or Fedora Media Writer
- [Alpine `setup-disk` source](https://github.com/alpinelinux/alpine-conf/blob/master/setup-disk.in) — what we're replacing at runtime
- [Alpine `apk --root` documentation](https://wiki.alpinelinux.org/wiki/Alpine_Linux_in_a_chroot) — how to install packages into a mounted root
- [systemd-boot](https://wiki.archlinux.org/title/Systemd-boot) — EFI boot manager for appliance images
- [bmaptool](https://github.com/yoctoproject/bmaptool) — optional `dd` replacement with checksums
- PlayOS ADR-0004 — Alpine Linux as reference OS base
- `playos-refdistro/docs/boot-budget.md` — first-frame timing constraints
- `playos-refdistro/docs/fast-boot.md` — boot optimization
