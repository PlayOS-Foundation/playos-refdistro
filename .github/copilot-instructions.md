# copilot-instructions.md — playos-refdistro

> **First:** Read `gen-context.md` for the full PlayOS platform context (architecture, repos, RFCs, ADRs).

## Purpose

This repository builds the Alpine-based PlayOS reference OS image for Runtime Devices. It produces a pre-built compressed GPT disk image (3 partitions: ESP + root + data) and a bootable ISO, both deployable via PXE.

## Build commands

### One-time host setup (Ubuntu Server)
```bash
bash scripts/setup-ubuntu-build-host.sh
```
Installs `systemd-container`, QEMU, OVMF; downloads and verifies Alpine 3.24 minirootfs into `.build/alpine-rootfs/`.

### Full build pipeline (disk image + ISO + PXE deploy)
```bash
bash scripts/build-iso-ubuntu.sh
```
Phases: create GPT layout → `systemd-nspawn` into Alpine root → build components + populate disk → install bootloader → compress + build ISO → deploy to PXE.

### Disk image only (inside nspawn)
```bash
bash scripts/build-disk-image.sh
```

### ISO only (inside nspawn)
```bash
bash scripts/build-alpine-iso.sh
```

### Component build (inside nspawn, called by the pipeline)
```bash
bash scripts/build-playos-components.sh
```
Builds `playos-platform-api`, `playos-runtime` (compositor), `playos-shell`, and samples with CMake+Ninja against musl.

### QEMU boot tests
```bash
bash scripts/test-disk-image-qemu.sh [path-to.img.zst]   # boots GPT image with OVMF
bash scripts/test-iso-qemu.sh [path-to.iso]              # boots ISO with OVMF
```
Pass criteria: systemd-boot → kernel → OpenRC → compositor started (serial console markers). Timeout: 150s.

### Build verification (artifact integrity check)
```bash
bash scripts/verify-build.sh
```
Checks: artifact existence + sizes, SHA-256 checksums, GPT/filesystem integrity, PXE deployment correctness.

### Environment overrides
```bash
PLAYOS_ALPINE_BRANCH=v3.24 PLAYOS_ARCH=x86_64 PLAYOS_IMAGE_SIZE_MB=6144
PLAYOS_RUNTIME_SRC=../playos-runtime PLAYOS_SHELL_SRC=../playos-shell
```

## Architecture

### Build host model
```
Ubuntu Server (host)
  → systemd-nspawn
  → official Alpine 3.24 minirootfs (.build/alpine-rootfs/)
  → apk + aports + mkimage (Alpine-native tooling)
  → out/*.iso + out/*.img.zst
  → PXE deploy to /var/www/html/playos/
```
Ubuntu only hosts the isolated Alpine build root. No Docker required (Docker is an optional alternative via `docker/Dockerfile`).

### Disk image layout
```
p1: ESP (vfat, 512 MiB)     — systemd-boot, kernels
p2: root (ext4, 4096 MiB)   — OS, read-only capable
p3: data (ext4, remaining)  — /data (games, saves, configs)
```
Image is zstd-compressed (~1 GiB). Shell's `InstallerScreen` writes it via native C++ `zstd | dd` pipeline, then grows p3 to fill the target disk. No shell-script installer.

### Boot chain
```
UEFI → systemd-boot → kernel + initramfs → OpenRC
  → playos-visual runlevel: seatd → playos-compositor → playos-shell
  → playos-async runlevel: audio, network, bluetooth (non-blocking)
```
Audio, network, and Bluetooth must never block the first frame. The compositor must never wait for background services.

### First-boot
`playos-firstboot` (one-shot OpenRC service, triggered by `/etc/playos/firstboot` flag): regenerates machine-id, filesystem UUIDs, updates fstab + boot entries, cleans stale EFI entries, applies pre-flight config from ESP, then self-deletes from runlevels.

## Key conventions

### Alpine-only profile
Alpine is the only supported distro. The retired Arch implementation is in Git history, not the active tree. A future distro backend needs its own proposal, packaging, image tooling, init definitions, tests, and release lifecycle. Do not share mutable state with the Alpine profile.

### Alpine-native mechanisms
Use apk, OpenRC, aports, mkimage, initramfs, modloop. Runtime and shell code builds on musl but must not depend on apk or OpenRC APIs. Distribution details must not leak into the public PlayOS API.

### Pinned releases only
Released images use a pinned Alpine stable branch. `build-alpine-iso.sh` explicitly rejects `edge`. Dockerfile pins `alpine:3.24.1`.

### Sibling repos
This repo expects sibling checkouts at `../playos-runtime`, `../playos-shell`, `../playos-platform-api`, `../playos-samples`. Override paths with environment variables.

### OpenRC service layout
- `playos-visual` runlevel: seatd, playos-compositor, dbus, sshd
- `playos-async` runlevel: audio, network, bluetooth, updates (starts after compositor)
- Init scripts live in `alpine/init.d/`

### Validation after every image change
Record: pinned Alpine tag, image digest, VM boot result, first-frame timestamp, renderer, kernel/Mesa/firmware/wlroots versions, hardware result when device-facing code changed.

### Docker ≠ hardware validation
Container success does not validate DRM/KMS, input, suspend, or firmware. Always test on QEMU/OVMF and reference hardware (ROG Ally).

### No secrets or host-specific paths
Debug SSH key in the image is a known development key — never commit production keys.

## Key files

| File | Purpose |
|---|---|
| `alpine/mkimg.playos.sh` | Alpine mkimage profile (kernel, initfs features, packages, cmdline) |
| `alpine/genapkovl-playos.sh` | Generates the apkovl overlay (config, init scripts, binaries, samples) |
| `alpine/packages.x86_64` | Declared package set (keep aligned with mkimg.playos.sh) |
| `alpine/init.d/playos-compositor` | OpenRC init script for the wlroots compositor |
| `alpine/init.d/playos-firstboot` | One-shot first-boot service |
| `scripts/build-iso-ubuntu.sh` | Canonical full-build entrypoint |
| `scripts/build-disk-image.sh` | Disk image creation + population |
| `scripts/build-playos-components.sh` | Cross-compiles C++ components against musl inside nspawn |
| `docs/service-order.md` | Boot chain and dependency rules |
| `docs/LiveISOImageBuild.md` | Step-by-step build guide with prerequisites |
| `ROADMAP.md` | Installation roadmap and task tracker |
