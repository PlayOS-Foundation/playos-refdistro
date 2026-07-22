# PlayOS Live ISO Image Build

This document describes the complete end-to-end process for building a PlayOS Live
ISO image from an Ubuntu Server host. It covers host setup, component compilation,
disk image construction, ISO generation, and post-build deployment.

For architectural context, see [alpine-migration.md](alpine-migration.md). For the
Ubuntu-native (non-Docker) build workflow overview, see
[ubuntu-native-build.md](ubuntu-native-build.md). For installation-to-disk, see
[PlayOS-Installation.md](PlayOS-Installation.md).

---

## 1. Prerequisites

### 1.1 Build Host

The build is designed for an **Ubuntu Server** (x86_64) host with:

- `sudo` access.
- Outbound HTTPS to `dl-cdn.alpinelinux.org` and `gitlab.alpinelinux.org`.
- Sufficient disk space for the Alpine rootfs (~1 GiB), aports checkout (~500 MiB),
  APK caches, work directories, and ISO output (several GiB total).
- KVM access recommended for fast QEMU boot tests.

### 1.2 Ubuntu Host Packages

`scripts/setup-ubuntu-build-host.sh` installs the following host-level packages
via `apt`:

| Package             | Purpose                                                  |
|---------------------|----------------------------------------------------------|
| `systemd-container`  | `systemd-nspawn` for running Alpine toolchains           |
| `qemu-system-x86`    | QEMU/OVMF ISO boot smoke test                            |
| `ovmf`               | UEFI firmware for QEMU                                   |
| `git`                | Clone aports and sibling repositories                    |
| `curl`               | Download Alpine minirootfs                               |
| `ca-certificates`    | HTTPS trust for downloads                                |
| `xz-utils`           | Compression/decompression support                        |

These are Ubuntu-specific host utilities; Alpine userspace tools (cmake, ninja,
wlroots, mesa, etc.) are installed later *inside* the nspawn container.

### 1.3 Sibling Repository Dependencies

The build expects these repositories as sibling directories alongside
`playos-refdistro`:

| Repository           | Default location            | Purpose                                |
|----------------------|-----------------------------|----------------------------------------|
| `playos-platform-api`| `../playos-platform-api`    | Platform abstraction layer headers     |
| `playos-runtime`     | `../playos-runtime`         | Runtime + wlroots compositor           |
| `playos-shell`       | `../playos-shell`           | Raylib shell UI + installer GUI        |
| `playos-samples`     | `../playos-samples`         | Example apps (hello-playos, space-invaders) |

Override paths with environment variables (see [Section 5](#5-build-overrides)).

---

## 2. Build Host Setup (One-Time)

Run once per build host or after changing the pinned Alpine version:

```bash
bash scripts/setup-ubuntu-build-host.sh
```

### 2.1 Alpine Minirootfs

The script downloads the official Alpine minirootfs archive:

```
https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-minirootfs-3.24.1-x86_64.tar.gz
```

The SHA-256 checksum is fetched and verified before extraction:

```
curl --output .build/cache/alpine-minirootfs-3.24.1-x86_64.tar.gz.sha256 ...
sha256sum --check ...
```

The archive is extracted into `.build/alpine-rootfs/` with `sudo tar --extract
--numeric-owner`. A version marker file `.playos-alpine-version` is written to
prevent accidentally overlaying a new Alpine version onto an existing root.

**Pinning rule:** The build is pinned to **Alpine v3.24**. Edge repositories are
explicitly forbidden — any attempt to use `edge` triggers a hard error.

### 2.2 Alpine Build Dependencies

After extraction, `scripts/install-alpine-build-deps.sh` runs inside the
minirootfs via `systemd-nspawn`. It:

1. Configures APK repositories for the pinned branch.
2. Installs Alpine build tooling: `abuild`, `alpine-sdk`, `build-base`, `cmake`,
   `ninja`, `git`, `squashfs-tools`, `xorriso`, `syslinux`, `mtools`, and others.

The resulting rootfs is cached in `.build/alpine-rootfs/`. Subsequent builds
reuse it without re-downloading or re-extracting.

---

## 3. Build Phases

The full build is orchestrated by `scripts/build-iso-ubuntu.sh`. It validates
that the Alpine rootfs marker exists, then proceeds through Phase 0–2.

```bash
bash scripts/build-iso-ubuntu.sh
```

### Phase 0: Disk Image Layout (Host)

A sparse GPT disk image is created on the **Ubuntu host** because `sgdisk` and
`losetup -P` need the host kernel for partition device nodes.

1. **Create sparse file:** `truncate -s 4096M out/playos-gpt-v3.24-x86_64.img`
2. **Partition with sgdisk:**
   - Partition 1: 512 MiB, type `EF00` (EFI System Partition)
   - Partition 2: remainder, type `8300` (Linux root)
3. **Format:**
   - `mkfs.vfat -F32 -n PLAYOS_EFI` on partition 1
   - `mkfs.ext4 -F -L playos-root` on partition 2
4. **Mount** via loop device at `/mnt/playos-image-root/`:
   - Root partition at `/mnt/playos-image-root/`
   - ESP at `/mnt/playos-image-root/boot/efi`
5. **Capture UUIDs:** Both filesystem UUIDs are recorded via `blkid` and passed
   into the nspawn container as `ROOT_UUID` and `EFI_UUID`.

A cleanup trap unmounts and detaches the loop device on exit.

### Phase 1: Inside systemd-nspawn Container

The nspawn container binds several directories:

| Host path                      | Container path            |
|--------------------------------|---------------------------|
| `$ROOT` (refdistro repo)       | `/workspace`              |
| `../playos-runtime`            | `/mnt/playos-runtime`     |
| `../playos-shell`              | `/mnt/playos-shell`       |
| `../playos-platform-api`       | `/mnt/playos-platform-api`|
| `../playos-samples`            | `/mnt/playos-samples`     |
| `/mnt/playos-image-root`       | `/mnt/playos-image-root`  |

Additional environment variables propagate: `PLAYOS_ROOT`, `PLAYOS_ALPINE_BRANCH`,
`PLAYOS_APORTS_BRANCH`, `PLAYOS_ARCH`, `DISK_MNT`, `ROOT_UUID`, `EFI_UUID`.

Three scripts are run in sequence inside the container.

#### 3a. Build PlayOS Components (`build-playos-components.sh`)

**Build dependencies** are installed inside the container:

```
apk add cmake ninja g++ make git ccache \
    wlroots0.19-dev wayland-dev wayland-protocols \
    libxkbcommon-dev libdrm-dev mesa-dev \
    raylib-dev glfw-dev seatd \
    gptfdisk parted e2fsprogs zstd dosfstools ...
```

**Build order:**

1. **playos-platform-api** — CMake/Ninja, Release build. Installed to the
   container's system for other components to link against.
2. **playos-runtime + compositor** — Built with `-DPLAYOS_BUILD_COMPOSITOR=ON`.
   Produces `playos-compositor`.
3. **playos-shell (Wayland)** — Built with `-DPLAYOS_SHELL_WAYLAND=ON` and
   `-DPLAYOS_USE_SYSTEM_RAYLIB=ON`. Uses Alpine's system raylib 5.0 (not
   FetchContent raylib 6.0). Produces `playos-shell` and `playos-installer-gui`.
4. **PlayOS samples** — `hello-playos` and `space-invaders`, also using system
   raylib. Output copied to `.build/samples-out/`.

**Installation:**

- Binaries installed to `/usr/bin/`: `playos-compositor`, `playos-shell`,
  `playos-installer-gui`
- Init script installed to `/etc/init.d/playos-compositor`
- Standalone installer script installed to `/usr/bin/playos-installer`
- Compositor symlinked into `/etc/runlevels/playos-visual/`

#### 3b. Populate Disk Image (`build-disk-image.sh`)

This script fills the pre-mounted disk image at `$DISK_MNT` with a complete
PlayOS system. When run standalone (without a pre-mounted image), it creates,
partitions, formats, and mounts its own image — the wrapper script handles this
so the nspawn invocation always supplies `DISK_MNT`.

**Steps:**

1. **APK repositories** are written to `$MNT/etc/apk/repositories` (pinned to
   `v3.24/main` and `v3.24/community`). APK signing keys are copied from the
   container.
2. **Alpine base system** installed via `apk --root $MNT --initdb add alpine-base`.
3. **PlayOS system packages** installed into the target root:
   - Display stack: `wlroots0.19`, `mesa-dri-gallium`, `mesa-egl`, `mesa-gbm`,
     `mesa-gles`, `mesa-vulkan-ati`, `mesa-vulkan-nouveau`, `mesa-vulkan-intel`,
     `libdrm`, `libinput`, `libxkbcommon`, `wayland`
   - GPU firmware: `linux-firmware-amdgpu`, `linux-firmware-nvidia`, `linux-firmware-intel`
   - Kernel: `linux-lts`
   - Services: `dbus`, `seatd`, `pipewire`, `wireplumber`, `networkmanager`,
     `bluez`, `openssh`, `iwd`, `wpa_supplicant`
   - Tools: `gptfdisk`, `glfw`, `raylib`, `zstd`, `eudev`, `alpine-conf`
   - OpenRC packages for each service (e.g., `networkmanager-openrc`,
     `seatd-openrc`)
4. **Custom binaries** copied into the target root:
   - `playos-compositor`, `playos-shell`, `playos-installer-gui` → `/usr/bin/`
   - Shared libraries: `libraylib.so.450`, `libglfw.so.3` → `/usr/lib/`
5. **Samples** copied from `.build/samples-out/` to `/usr/share/playos/`.
6. **Init scripts** installed:
   - `playos-compositor` → `/etc/init.d/`
   - `playos-firstboot` → `/etc/init.d/`
7. **OpenRC runlevels** configured via a `rc_add` helper:

   | Runlevel  | Services                                                    |
   |-----------|-------------------------------------------------------------|
   | `sysinit` | `devfs`, `dmesg`, `udev`, `udev-trigger`, `hwdrivers`, `modloop` |
   | `boot`    | `hwclock`, `modules`, `sysctl`, `hostname`, `bootmisc`, `syslog` |
   | `default` | `dbus`, `seatd`, `playos-compositor`, `networkmanager`, `wpa_supplicant`, `sshd`, `playos-firstboot` |
   | `shutdown`| `mount-ro`, `killprocs`, `savecache`                        |

8. **Configuration files:**
   - Hostname: `playos`
   - SSH debug key: pre-configured ed25519 key at `/root/.ssh/authorized_keys`
   - Kernel cmdline: `console=tty0 amdgpu.sg_display=0 quiet loglevel=3`
   - fstab: UUID-based entries for root (ext4) and ESP (vfat)
   - First-boot flag: `/etc/playos/firstboot`
9. **Bootloader installation** (`systemd-boot`):
   - `bootctl install --root=$MNT --esp-path=/boot/efi --no-variables`
   - Entry created at `loader/entries/playos.conf` with kernel, initramfs, and
     root UUID
   - Kernel and initramfs copied to ESP for direct booting
   - Falls back gracefully if `bootctl` is unavailable in the build environment

#### 3c. Compress Disk Image

After populating, the disk image is compressed inside the container:

```bash
zstd -f -T2 --rm -12 out/playos-gpt-v3.24-x86_64.img
sha256sum out/playos-gpt-v3.24-x86_64.img.zst > out/playos-gpt-v3.24-x86_64.img.zst.sha256
```

The 4 GiB uncompressed image compresses to approximately 800 MiB.

#### 3d. Build ISO (`build-alpine-iso.sh`)

This script produces the bootable Live ISO using Alpine's `mkimage.sh` tooling.

1. **Clone/update Alpine aports:**

   ```bash
   git clone --depth 1 --branch 3.24-stable \
       https://gitlab.alpinelinux.org/alpine/aports.git /var/cache/playos-aports
   ```

   The `3.24-stable` tag is pinned; unpinned `edge` is rejected.

2. **Install PlayOS profile files** into the aports tree:
   - `alpine/mkimg.playos.sh` → `aports/scripts/mkimg.playos.sh` (profile definition)
   - `alpine/genapkovl-playos.sh` → `aports/genapkovl-playos.sh` (apkovl generator)

3. **Install initfs feature files:**
   - `usbnet.modules`, `amdgpu.modules`, `nvidia.modules` → `/etc/mkinitfs/features.d/`
   - `amdgpu-firmware.files`, `nvidia-firmware.files` → `/etc/mkinitfs/features.d/`
   - These ensure GPU kernel modules and firmware are bundled into the initramfs
     so GPU probing works before the APK overlay is extracted.

4. **Patch mkimage scripts for nspawn compatibility:**
   - Strip `--no-chown` from `scripts/mkimage.sh` (conflicts with running as root
     in nspawn).
   - Remove `sd-mod,usb-storage,quiet` from the default `initfs_cmdline` in
     `scripts/mkimg.base.sh` (these probe hardware that can hang during netboot;
     quiet suppresses debug output).

5. **Install GPU firmware** on the build host via `apk add linux-firmware-amdgpu
   linux-firmware-nvidia linux-firmware-intel`.

6. **Generate abuild signing keys** for a non-root `build` user and copy them to
   `/etc/apk/keys/`.

7. **Run mkimage.sh:**

   ```bash
   sh scripts/mkimage.sh \
       --tag v3.24 \
       --outdir /workspace/out \
       --arch x86_64 \
       --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/main \
       --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/community \
       --profile playos
   ```

   The `playos` profile (defined in `mkimg.playos.sh`) specifies the APK package
   list, kernel (`lts`), initfs features (`network usbnet amdgpu amdgpu-firmware
   nvidia nvidia-firmware`), kernel cmdline (including netboot parameters), and
   the `genapkovl-playos.sh` overlay generator.

   The overlay generator (`genapkovl-playos.sh`) creates `playos.apkovl.tar.gz`,
   which bundles:
   - Hostname, APK world file
   - OpenRC runlevel configuration (`playos-visual` with dbus, seatd, compositor, sshd)
   - SSH authorized keys
   - `playos-compositor`, `playos-shell`, `playos-installer-gui` binaries
   - `libraylib.so.450`, `libglfw.so.3` shared libraries
   - Pre-built samples (`hello-playos`, `space-invaders`)
   - The compressed disk image (`.img.zst`) at `/usr/share/playos/`

   Output lands in `out/` as a bootable ISO file.

### Phase 2: Post-Build (Host)

After the nspawn container exits, the host wrapper:

1. **Fixes ownership** of the compressed disk image and checksum (created as
   root inside nspawn).
2. **Displays built artifacts:**
   ```
   out/playos-gpt-v3.24-x86_64.img.zst
   out/playos-gpt-v3.24-x86_64.img.zst.sha256
   out/*.iso
   ```

#### PXE Deployment

The ISO is loop-mounted and its contents are deployed to
`/var/www/html/playos/`:

| File                       | Source                          |
|----------------------------|---------------------------------|
| ISO                        | `out/*.iso`                     |
| `playos.apkovl.tar.gz`     | ISO root                        |
| `vmlinuz-lts`              | ISO `/boot/`                    |
| `initramfs-lts`            | ISO `/boot/`                    |
| `modloop-lts`              | ISO `/boot/`                    |
| APK repository cache       | ISO `/apks/`                    |
| Compressed disk image      | `out/*.img.zst` + `.sha256`     |

Files are owned by `www-data` for HTTP serving.

---

## 4. Key Files in `alpine/`

| File | Purpose |
|------|---------|
| `mkimg.playos.sh` | **Alpine mkimage profile.** Defines the ISO architecture (`x86_64`), kernel flavor (`lts`), APK package list, initfs features (GPU modules, USB networking), kernel command line (netboot + display workarounds), and the apkovl generator script. This is the single source of truth for what the ISO contains. |
| `genapkovl-playos.sh` | **APK overlay generator.** Produces `playos.apkovl.tar.gz` — a gzipped tarball applied on top of the ISO's read-only filesystem at boot. Bundles OpenRC runlevels, compositor/shell/installer binaries, shared libraries, SSH keys, samples, and the compressed disk image. |
| `packages.x86_64` | **Reference package list** (informational). Documents the expected package set; kept aligned with `mkimg.playos.sh`. |
| `init.d/playos-compositor` | **OpenRC init script** for the wlroots Wayland compositor. Requires `seatd` and `localmount`, creates `XDG_RUNTIME_DIR`, and launches `playos-compositor -- playos-shell` as a background daemon with logging. |
| `init.d/playos-firstboot` | **One-shot first-boot service.** Runs exactly once after a disk image is written to a target device. Regenerates `machine-id`, randomizes filesystem UUIDs, updates fstab and systemd-boot entries, cleans stale EFI boot entries, creates a PlayOS EFI boot entry, and removes itself from runlevels. |
| `init.d/playos-installer` | **Superseded OpenRC installer.** Replaced by the standalone script at `install-script/playos-installer` and the raylib GUI executable. Kept for reference only; not installed by the build. |
| `install-script/playos-installer` | **Standalone shell installer.** Spawned by `playos-installer-gui` as a child process. Reads the target disk from `/run/playos/install-target`, runs `setup-disk`, writes progress stages to `/run/playos/install-status` for the GUI to poll, configures post-install services, and triggers reboot. |
| `amdgpu.modules` | Initfs kernel module path: `kernel/drivers/gpu/drm/amd` |
| `nvidia.modules` | Initfs kernel module path: `kernel/drivers/gpu/drm/nouveau` |
| `usbnet.modules` | Initfs kernel module path: `kernel/drivers/net/usb` (enables USB-C dock NICs on devices like the ROG Ally) |
| `amdgpu-firmware.files` | Initfs firmware path: `lib/firmware/amdgpu` |
| `nvidia-firmware.files` | Initfs firmware path: `lib/firmware/nvidia` |

---

## 5. Build Overrides

Environment variables that control the build process:

| Variable                  | Default                          | Description                                        |
|---------------------------|----------------------------------|----------------------------------------------------|
| `PLAYOS_ALPINE_BRANCH`    | `v3.24`                          | Alpine release branch (tag format)                 |
| `PLAYOS_APORTS_BRANCH`    | `3.24-stable`                    | Alpine aports Git branch                           |
| `PLAYOS_ARCH`             | `x86_64`                         | Target architecture                                |
| `PLAYOS_ROOT`             | `/workspace`                     | Workspace root inside nspawn                       |
| `PLAYOS_IMAGE_SIZE_MB`    | `4096`                           | Disk image capacity in MiB                         |
| `PLAYOS_ESP_SIZE_MB`      | `512`                            | EFI system partition size in MiB                   |
| `PLAYOS_RUNTIME_SRC`      | `$ROOT/../playos-runtime`        | Path to playos-runtime checkout                    |
| `PLAYOS_SHELL_SRC`        | `$ROOT/../playos-shell`          | Path to playos-shell checkout                      |
| `PLAYOS_PLATFORM_SRC`     | `$ROOT/../playos-platform-api`   | Path to playos-platform-api checkout               |
| `PLAYOS_SAMPLES_SRC`      | `$ROOT/../playos-samples`        | Path to playos-samples checkout                    |

Example with overrides:

```bash
PLAYOS_ALPINE_BRANCH=v3.24 \
PLAYOS_IMAGE_SIZE_MB=8192 \
PLAYOS_RUNTIME_SRC=/path/to/custom/playos-runtime \
bash scripts/build-iso-ubuntu.sh
```

---

## 6. Output Artifacts

After a successful build, `out/` contains:

| File                                              | Size (approx.) | Description                                 |
|---------------------------------------------------|----------------|---------------------------------------------|
| `playos-gpt-v3.24-x86_64.img.zst`                 | ~800 MiB       | Zstd-compressed GPT disk image              |
| `playos-gpt-v3.24-x86_64.img.zst.sha256`          | < 1 KiB        | SHA-256 checksum of the compressed image    |
| `alpine-playos-*-x86_64.iso`                      | ~1.5 GiB       | Bootable Live ISO (name varies by mkimage)  |

The uncompressed disk image is 4 GiB (default), partitioned as GPT with a 512 MiB
ESP and a 3.5 GiB ext4 root.

---

## 7. Testing

### QEMU / OVMF Headless Boot Test

```bash
bash scripts/test-iso-qemu.sh
```

Or target a specific ISO:

```bash
bash scripts/test-iso-qemu.sh out/alpine-playos-*.iso
```

The test script:

1. Locates the most recent ISO in `out/` (or uses the explicit path).
2. Finds OVMF firmware files (`OVMF_CODE_4M.fd`, `OVMF_VARS_4M.fd`).
3. Configures QEMU with:
   - **Machine:** `q35` with KVM acceleration if `/dev/kvm` is writable,
     otherwise TCG software emulation.
   - **CPU:** `host` (KVM) or `max` (TCG).
   - **Memory:** 2 GiB, 4 SMP cores.
   - **Display:** `virtio-vga`, headless (`-display none`).
   - **Serial console:** `ttyS0` at 115200 baud, connected to the terminal.
   - **Network:** user-mode NAT with virtio-net-pci.
   - **Boot:** CD-ROM first, no reboot on exit.

The Alpine profile exposes `ttyS0` at 115200 baud. Press `Ctrl-A X` to exit
QEMU.

Kernel command line adjustments in the ISO profile (`mkimg.playos.sh`) set
`loglevel=7` and enable `ip=dhcp` for netboot compatibility. The `softlevel`
is set to `playos-visual` so the compositor starts immediately on the live image.

---

## 8. Rebuilds and Version Changes

### Incremental Rebuilds

The Alpine minirootfs, aports checkout, abuild keys, and caches persist beneath
`.build/`. ISO work data is recreated for each build. Re-running
`scripts/build-iso-ubuntu.sh` is safe — it reuses cached artifacts.

### Changing Alpine Versions

To upgrade or change the Alpine version, move the existing rootfs aside first:

```bash
mv .build/alpine-rootfs .build/alpine-rootfs.previous
bash scripts/setup-ubuntu-build-host.sh
```

The version marker check prevents silent overwrites. If the version has changed,
the setup script will refuse to run until the old rootfs is moved.

### Cleaning

```bash
bash scripts/clean.sh
```

Removes all files in `out/`. Does not affect `.build/` caches.

---

## 9. Architecture Notes

### Boot Chain (Live ISO)

```text
UEFI → systemd-boot → Linux LTS kernel → initramfs (with GPU modules/firmware)
  → modloop → APK overlay (playos.apkovl.tar.gz)
  → playos-visual runlevel
      → dbus → seatd → playos-compositor → playos-shell
```

### Boot Chain (Installed Disk)

```text
UEFI → systemd-boot (playos.conf entry) → Linux LTS kernel
  → initramfs → ext4 root
  → default runlevel
      → dbus → seatd → playos-compositor → playos-shell
  → playos-firstboot (one-shot, removes itself after first boot)
```

### Service Order

The compositor must never wait for a background service. See
[service-order.md](service-order.md) and [boot-budget.md](boot-budget.md) for
the first-frame timing budget and dependency rules.

### Compatibility

All runtime components (compositor, shell, samples) build against **musl libc**.
glibc-only payloads must run through declared compatibility runtimes — do not
add glibc to the base OS.
