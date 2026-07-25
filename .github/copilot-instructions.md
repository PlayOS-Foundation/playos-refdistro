## Build, test, and lint

```bash
# First-time Ubuntu host setup (downloads + verifies Alpine minirootfs, installs deps)
bash scripts/setup-ubuntu-build-host.sh

# Full pipeline: build components → disk image → ISO → PXE deploy
bash scripts/build-iso-ubuntu.sh

# Disk image only (run inside nspawn or with pre-mounted DISK_MNT)
bash scripts/build-disk-image.sh

# ISO only (inside nspawn, after disk image is built)
bash scripts/build-alpine-iso.sh

# Verify build artifacts (GPT integrity, filesystem checks, checksums, PXE)
bash scripts/verify-build.sh

# Boot disk image in QEMU/OVMF (monitors serial for boot markers)
bash scripts/test-disk-image-qemu.sh [path-to.img.zst]

# Boot ISO in QEMU/OVMF (interactive serial console)
bash scripts/test-iso-qemu.sh [path-to.iso]

# Clean output directory
bash scripts/clean.sh
```

Environment variables that control the build:
`PLAYOS_ALPINE_VERSION` (default `3.24.1`), `PLAYOS_ALPINE_BRANCH` (default `v3.24`), `PLAYOS_ARCH` (default `x86_64`), `PLAYOS_IMAGE_SIZE_MB` (default `6144`), `PLAYOS_ESP_SIZE_MB` (default `512`), `PLAYOS_ROOT_SIZE_MB` (default `4096`).

There are no unit tests in this repo — it is a distro packaging/integration repo. Validation is done via QEMU boot tests and verify-build.sh artifact checks.

## Architecture

This repo builds the **Alpine-based PlayOS reference operating system** as a pre-built disk image + bootable ISO. It is not the OS itself — it is the packaging, configuration, and image tooling for the OS.

**Build host model:** The primary workflow runs on an Ubuntu Server host. Ubuntu uses `systemd-nspawn` to enter a checksum-verified Alpine minirootfs, where Alpine's native tooling (apk, mkimage, aports) runs. Docker is an optional alternative for Windows/macOS. Both call the same `scripts/build-alpine-iso.sh` entrypoint.

**Build pipeline (3-phase):**
1. **Host side (Ubuntu):** Partition + format a 3-partition GPT disk image (ESP 512M, root 4G, data fills remainder). Mount partitions.
2. **nspawn side (Alpine):** `build-playos-components.sh` builds sibling repos (platform-api, runtime/compositor, shell, samples) with cmake+ninja against musl. `build-disk-image.sh` installs Alpine base + packages into the mounted root partition, configures OpenRC runlevels, installs systemd-boot to ESP, bundles compositor/shell/samples binaries.
3. **Post-nspawn (Ubuntu):** Compress disk image with zstd, rebuild ISO with xorriso (workaround for nspawn xorriso apkovl corruption), deploy to PXE server.

**Outputs in `out/`:**
- `playos-gpt-v3.24-x86_64.img.zst` — compressed GPT disk image with 3 partitions
- `alpine-playos-v3.24-x86_64.iso` — bootable ISO (bundles the disk image + apkovl)

**OpenRC service architecture (boot order is policy):**
- `playos-visual` runlevel (first-frame critical): seatd → playos-compositor → playos-shell. Networking (NetworkManager, wpa_supplicant) and SSH also start here but don't block the compositor.
- `playos-async` runlevel: audio, bluetooth, library, updates — starts after compositor readiness.
- `playos-firstboot` (one-shot, default runlevel): regenerates machine-id, filesystem UUIDs, creates EFI boot entry, applies pre-flight config from ESP, then deletes itself from runlevels.
- The compositor must never wait for a background service.

**Partition layout (GPT):**
- `p1`: EFI System Partition (vfat, 512M) — systemd-boot, kernel, initramfs
- `p2`: root (ext4, 4G) — Alpine system + PlayOS binaries
- `p3`: data (ext4, fills remainder) — `/data/games`, `/data/saves`, `/data/config`

## Key conventions

**Alpine-native only.** Use apk, OpenRC, aports, mkimage, initramfs, and supported Alpine persistence patterns. The retired Arch implementation is in Git history only — don't reference or revive it.

**Pinned releases.** Alpine `v3.24` stable only. The build script explicitly rejects `edge`. Package repositories are pinned to `dl-cdn.alpinelinux.org/alpine/v3.24/main` and `community`.

**First-frame-first.** The visual boot path (GPU/input → seatd → compositor → shell) must not be delayed by audio, networking, bluetooth, or cloud services. The boot budget targets < 2 seconds from kernel handoff to first shell frame. Any new service on the visual path must be measured.

**No secrets or host-specific paths.** The debug SSH key in `genapkovl-playos.sh` and `build-disk-image.sh` is intentionally public. Don't add real credentials.

**Sibling repo layout.** Build scripts resolve sibling repos (`playos-runtime`, `playos-shell`, `playos-platform-api`, `playos-samples`) via relative paths (`../playos-*/`) or environment variables. These repos must exist as siblings at build time.

**Two output artifacts, one source.** Both the `.img.zst` disk image and `.iso` are produced from the same Alpine rootfs population. Changes to packages, init scripts, or overlays in `alpine/` affect both.

**systemd-boot, not GRUB.** The bootloader is systemd-boot installed to the ESP. Boot entries live in `loader/entries/playos.conf`. The kernel cmdline includes `amdgpu.sg_display=0` (ROG Ally workaround, harmless elsewhere) and serial console for debugging.

**Docker does not validate hardware.** Container boot success does not prove DRM/KMS, input, suspend, or firmware work. Always test on VM (QEMU/OVMF) and reference hardware (ROG Ally) for device-facing changes.

**musl, not glibc.** All binaries in the image are compiled against musl. Don't add glibc as a base dependency. glibc-only software needs a compatibility runtime.
