# AGENTS.md — playos-refdistro

> **⚠️ FIRST:** Read [`gen-context.md`](gen-context.md) before anything else to understand the full PlayOS platform context.

## Project overview

This repository builds the **PlayOS reference operating system images** for full
Runtime Devices (game-console-style appliances, primary hardware: ASUS ROG Ally).
It is a **distro packaging and integration repo**: there is no compiled code and
no unit-test suite here — only Bash build scripts, image profiles, init/service
definitions, and documentation.

PlayOS itself is a specification-first console platform (see `gen-context.md`).
Platform behaviour is specified in the sibling `playos-spec` repository;
**ADR-0004** selects Alpine Linux, musl, apk, and OpenRC as the reference OS.
Distribution details must not leak into the public PlayOS API.

The image is a console appliance: it boots directly into the PlayOS wlroots
compositor and Raylib shell ("first frame first"), then starts non-visual
services asynchronously.

Two distro backends are supported, producing identical output formats
(compressed GPT disk image + bootable ISO):

| Backend | Status | Base | Init | Kernel |
|---|---|---|---|---|
| **Alpine** (`alpine/`) | Reference | Alpine 3.24 stable, musl, apk | OpenRC | `linux-stable` (7.1.x, includes `asus-armoury`) |
| **Arch + CachyOS** (`arch/`) | Alternative backend (handheld/desktop optimized) | Pinned Arch snapshot + CachyOS repos, glibc, pacman | systemd | `linux-cachyos` (EEVDF/ThinLTO) or `linux-cachyos-deckify` (BORE + handheld patches) |

## Golden rules

1. **First frame first.** Only GPU/input readiness, seatd, compositor, and shell
   belong on the visual path. The compositor must never wait for a background
   service; a background service may wait for compositor readiness.
2. **Use distro-native mechanisms.** Alpine work uses apk, OpenRC, aports,
   mkimage, initramfs, modloop. Arch work uses pacman, systemd, mkinitcpio.
3. **Pin releases.** Released images use the pinned Alpine stable branch
   (`v3.24`, aports `3.24-stable`) or the pinned Arch archive snapshot +
   CachyOS repos. Unpinned `edge` builds are rejected by the build scripts.
4. **Support multiple distro backends.** Alpine is the reference. Distro-specific
   code lives in `alpine/` or `arch/`; shared logic lives in `shared/`. A future
   backend must be proposed separately and own its packaging, image tooling,
   init/service definitions, tests, and release lifecycle — it must not share
   mutable implementation state with the Alpine profile.
5. **Keep runtime code distribution-independent.** Package/init/image code
   belongs here. The PlayOS runtime and shell sources (sibling repos) must build
   on musl without depending on apk or OpenRC APIs.
6. **A successful build validates nothing about hardware.** Image builds do not
   validate DRM/KMS, input, suspend, or firmware. Always run the QEMU tests, and
   ROG Ally hardware tests for device-facing changes.
7. **No secrets or host-specific paths.** The embedded `playos-debug` SSH key is
   intentionally public. Never commit real credentials.

## Repository layout

```text
playos-refdistro/
├── alpine/                  # Authoritative Alpine profile
│   ├── mkimg.playos.sh      #   Alpine mkimage profile (kernel_flavors="stable", ISO package set)
│   ├── genapkovl-playos.sh  #   Live-image apkovl overlay: world file, runlevels, NM config, SSH key
│   ├── packages.x86_64      #   Reviewable package inventory (keep aligned with mkimg.playos.sh)
│   ├── init.d/              #   OpenRC services (see Service policy below)
│   ├── *.modules / *-firmware.files  # mkinitfs feature files (GPU modules + firmware globs)
│   └── boot.ipxe / boot-debug.ipxe   # iPXE netboot scripts
├── arch/                    # Arch + CachyOS profile
│   ├── pacman.conf          #   Pinned archive.archlinux.org snapshot (2026/07/01) + CachyOS repos
│   ├── packages.x86_64      #   General variant package set (linux-cachyos)
│   ├── packages-handheld.x86_64  # Handheld variant (linux-cachyos-deckify + asusctl)
│   ├── mkinitcpio.conf      #   Initramfs hooks/modules
│   ├── systemd/             #   seatd.service, playos-compositor.service, playos-firstboot.service
│   └── boot.ipxe
├── shared/                  # Distro-agnostic logic sourced by the scripts
│   ├── partition-layout.sh  #   create_disk_layout(): GPT image, format, mount, UUID capture
│   ├── bootloader-install.sh#   install_bootloader(): systemd-boot to ESP (host-side)
│   ├── fstab-generate.sh    #   generate_fstab()
│   ├── device-profiles.sh   #   deploy_device_profiles(): TOML profiles → /etc/playos/device-profiles/
│   ├── firstboot-common.sh  #   First-boot logic shared by OpenRC and systemd (Arch consumes this)
│   ├── verify-sibling-repos.sh
│   ├── logging.sh           #   Full structured logging library (host-side scripts)
│   └── logging-helpers.sh   #   Lightweight wrapper for nspawn-inner/standalone scripts
├── scripts/                 # Build, test, and deployment entrypoints (see below)
├── patches/                 # aports-mkimage.patch + regeneration procedure (README.md)
├── docs/                    # Canonical documentation (index: docs/README.md)
├── out/                     # Build artifacts (gitignored)
├── .build/                  # nspawn build roots, caches, QEMU state (gitignored)
└── logs/                    # Structured per-run build logs (gitignored)
```

Sibling repositories (required at build time, expected as flat checkouts next to
this repo under `/home/nikmes/playos/`): `playos-runtime` (compositor),
`playos-shell`, `playos-platform-api`, `playos-samples`; optional:
`playos-reference-devices` (TOML device profiles). Locations are overridable via
`PLAYOS_RUNTIME_SRC`, `PLAYOS_SHELL_SRC`, `PLAYOS_PLATFORM_SRC`,
`PLAYOS_SAMPLES_SRC`, `PLAYOS_REFERENCE_DEVICES`.

## Build process

The supported build host is **x86_64 Ubuntu Server**. Ubuntu only hosts an
isolated, checksum-verified build root (`systemd-nspawn`); all image tooling
runs with the target distro's native tools inside that root. This is not a
second distro implementation.

### Setup (first time, per backend)

```bash
bash scripts/setup-ubuntu-build-host.sh                       # Alpine (default)
PLAYOS_DISTRO=arch bash scripts/setup-ubuntu-build-host.sh    # Arch
```

- Alpine: downloads `alpine-minirootfs-3.24.1-x86_64.tar.gz`, verifies the
  official SHA-256, extracts to `.build/alpine-rootfs/`, installs build deps
  (`install-alpine-build-deps.sh`). A version marker prevents silently mixing
  releases; move the rootfs aside before changing versions.
- Arch: downloads a version-pinned Arch bootstrap tarball, installs
  `arch/pacman.conf` + CachyOS mirrorlist, initializes the pacman keyring,
  installs build deps (`install-arch-build-deps.sh`).

### Full pipeline

```bash
# Alpine (reference)
bash scripts/build-iso-ubuntu.sh

# Arch + CachyOS (general optimized)
PLAYOS_DISTRO=arch PLAYOS_KERNEL_VARIANT=cachyos bash scripts/build-iso-ubuntu.sh

# Arch + CachyOS (handheld optimized — ROG Ally, Steam Deck)
PLAYOS_DISTRO=arch PLAYOS_KERNEL_VARIANT=deckify bash scripts/build-iso-ubuntu.sh
```

`build-iso-ubuntu.sh` is the sole orchestrator and distro dispatcher. Phases:

0. **GPT layout (host).** `shared/partition-layout.sh` creates the sparse image,
   partitions (ESP 512 MiB vfat `PLAYOS_EFI`, root 4 GiB ext4 `playos-root`,
   data ext4 `playos-data` filling the remainder), formats, mounts at
   `/mnt/playos-image-root`, captures UUIDs.
1. **Component build + disk population (nspawn).**
   `scripts/build-playos-components.sh` builds Raylib 6.0 from source
   (`libraylib.so.600` — Alpine 3.24 ships only 5.0), then Platform API,
   Runtime + compositor (`-DPLAYOS_BUILD_COMPOSITOR=ON`), Shell
   (`-DPLAYOS_SHELL_WAYLAND=ON -DPLAYOS_USE_SYSTEM_RAYLIB=ON`), and samples with
   CMake + Ninja; on Alpine it also builds the out-of-tree `hid-asus-ally`
   ROG Ally controller kernel module (`build-hid-asus-ally.sh`, pinned commit,
   against `linux-stable-dev`). Then `build-disk-image-alpine.sh` (apk) or
   `build-disk-image-arch.sh` (`pacman -r`) installs the base system, kernel,
   firmware, generates the initramfs (mkinitfs / mkinitcpio — with GPU firmware
   inclusion verified by decompressing the image and grepping the listing),
   copies PlayOS binaries and samples in, deploys device profiles, and
   configures services, NetworkManager, fstab, and the SSH debug key.
2. **Bootloader (host).** `shared/bootloader-install.sh` installs systemd-boot
   to the ESP (must run on the host — nspawn `--bind` does not propagate the
   nested ESP mount).
3. **Compress + ISO (nspawn).** The orchestrator is the **sole owner** of
   compression: `zstd -f -T0 --rm -12` + `sha256sum`. Then
   `build-alpine-iso.sh` (Alpine aports mkimage, then an xorriso rebuild from a
   DESTDIR backup — workaround for apkovl corruption inside nspawn) or
   `build-arch-iso.sh` (xorriso + mtools FAT ESP image) bundles the
   pre-compressed `.img.zst` into the ISO. The ISO scripts never compress.
4. **Finalize + PXE deploy (host).** Fixes ownership, publishes artifacts to the
   PXE server directory `/var/www/html/playos/` (ISO, kernel, initramfs, Alpine
   apkovl/modloop/apks or Arch equivalents, `boot.ipxe`; `www-data` ownership).

### Outputs (`out/`)

| Artifact | Produced by |
|---|---|
| `playos-gpt-alpine-v3.24-x86_64.img.zst` (+ `.sha256`) | Alpine pipeline |
| `alpine-playos-v3.24-x86_64.iso` | Alpine pipeline (bundles the `.img.zst`) |
| `playos-gpt-arch-{cachyos,deckify}-x86_64.img.zst` (+ `.sha256`) | Arch pipeline |
| `playos-arch-{cachyos,deckify}-x86_64.iso` | Arch pipeline |

### Key environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PLAYOS_DISTRO` | `alpine` | Backend selector (`alpine` / `arch`) |
| `PLAYOS_KERNEL_VARIANT` | `cachyos` | Arch kernel: `cachyos` / `deckify` |
| `PLAYOS_ALPINE_VERSION` | `3.24.1` | Minirootfs version |
| `PLAYOS_ALPINE_BRANCH` | `v3.24` | Alpine branch (`edge` is rejected) |
| `PLAYOS_APORTS_BRANCH` | `3.24-stable` | aports branch for mkimage |
| `PLAYOS_ARCH` | `x86_64` | Target architecture |
| `PLAYOS_IMAGE_SIZE_MB` / `PLAYOS_ESP_SIZE_MB` / `PLAYOS_ROOT_SIZE_MB` | `6144` / `512` / `4096` | Disk image geometry |
| `PLAYOS_SSH_PUBKEY` | repo `playos-debug` key | SSH debug key baked into images (auto-detects `~/.ssh/id_*.pub`) |
| `PLAYOS_WIFI_SSID` / `PLAYOS_WIFI_PSK` | unset | Bake a WiFi auto-connect profile into the image (debug) |
| `PLAYOS_LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |
| `PLAYOS_ARCH_SNAPSHOT` / `PLAYOS_ARCH_BOOTSTRAP_VER` | `2026/07/01` / `2026.07.01` | Arch pinning |

### aports patch management

`patches/aports-mkimage.patch` carries four modifications to Alpine's aports
scripts (remove `--no-chown`, `cp -Lrs` → `cp -rL`, DESTDIR backup before
xorrisofs, strip `sd-mod,usb-storage quiet` from `initfs_cmdline`). It is
applied by `scripts/apply-aports-patches.sh` via `git apply --check` then
`git apply` — a mismatch with upstream **fails the build loudly** instead of
silently producing a broken ISO. When Alpine updates aports, regenerate the
patch following `patches/README.md`.

### Cleaning

```bash
bash scripts/clean.sh                 # remove out/ artifacts (preserves .build/)
bash scripts/clean-cache.sh           # clean ccache/CMake/APK caches
bash scripts/clean-cache.sh --full    # also remove .build/ (build roots)
```

## Runtime architecture (what the images do)

### Boot policy — the first-frame rule

```text
UEFI → systemd-boot → kernel + initramfs → root
→ playos-visual (OpenRC softlevel; systemd units on Arch)
→ GPU/input readiness → seatd → playos-compositor → playos-shell first frame
→ playos-async-trigger → playos-async: NetworkManager + iwd + sshd
→ playos-firstboot (one-shot, first boot only)
```

- `playos-visual` contains only the first-frame path: `dbus`, `seatd`,
  `playos-compositor`, `playos-async-trigger` (and `playos-firstboot` on the
  installed image). `playos-async` is reserved for audio, networking, Bluetooth,
  library, updates, cloud, marketplace, telemetry, and debug services.
- The compositor service (`alpine/init.d/playos-compositor`) waits up to 10 s
  for a `/dev/dri/card*` node, stages the device profile from
  `/etc/playos/device-profiles/` to `/run/playos/profiles/` (tomlplusplus
  segfaults reading TOML from ext4 — read from tmpfs instead), starts
  `playos-compositor -- playos-shell`, detects fast crashes, then writes
  `/run/playos-visual-ready`.
- `playos-async-trigger` polls that flag (15 s timeout) and activates the async
  runlevel with `openrc --no-stop playos-async`. The `--no-stop` is **critical**:
  a plain `openrc <runlevel>` switches runlevels and stops everything not in the
  target, which kills seatd and the compositor.
- On Arch, systemd units mirror this: `seatd.service` →
  `playos-compositor.service` (with the same tmpfs profile staging) →
  `playos-firstboot.service` (oneshot, gated on `/etc/playos/firstboot`).
- Boot budget: cold boot to first shell frame < 8 s (acceptance), < 3 s
  (target). Any service added to the visual path must record a measured
  first-frame impact.
- Kernel cmdline includes `amdgpu.sg_display=0` (ROG Ally Display Core
  workaround, harmless elsewhere) and serial consoles for debugging.

### Installation model and first boot

PlayOS ships a **pre-built compressed GPT disk image** written to disk by the
Shell's integrated installer (`zstd | dd`, then GPT partition resize). There is
no shell-script installer and no network at install time; the standalone
`playos-installer` is retired (installer UI lives in `playos-shell`).

`playos-firstboot` runs exactly once (flag file `/etc/playos/firstboot`):
applies optional pre-flight config written by the installer to the ESP
(`playos-install-config`: hostname, timezone, WiFi, display name, locale),
regenerates machine-id and filesystem UUIDs, grows root/data filesystems with
`resize2fs`, updates fstab and the systemd-boot entry, removes stale EFI boot
entries, creates a PlayOS EFI entry, then deletes itself from all runlevels.
The OpenRC implementation is `alpine/init.d/playos-firstboot`; the Arch systemd
unit executes the shared `shared/firstboot-common.sh` — keep the two
implementations in sync when changing first-boot behaviour.

### Data partition and device profiles

- `/data` (ext4, fills the disk) holds `/data/games`, `/data/saves`,
  `/data/config`.
- Device profiles are TOML files from `playos-reference-devices`, installed to
  `/etc/playos/device-profiles/<device>.toml`. `PLAYOS_PROFILE` selects the
  active profile (default `rog-ally`).

### Networking and debug access

- NetworkManager with the **iwd** WiFi backend (`wifi.backend=iwd`), internal
  DHCP, connectivity check disabled, and a catch-all wired DHCP profile.
- `sshd` runs in `playos-async` with a root key (public debug key by default).
- `playos-usb-gadget` — REMOVED: g_serial kernel module unavailable; ROG Ally USB-C is host-only.
- Runtime logs on device: `/var/log/playos-compositor.log`,
  `/var/log/playos-firstboot.log`. Set `PLAYOS_DEBUG=1` for wlroots debug output.
- PXE netboot: `scripts/setup-pxe-server.sh` configures an Ubuntu host
  (nginx + dnsmasq DHCP proxy + iPXE); `alpine/boot.ipxe` / `arch/boot.ipxe`
  chain-load kernel and initramfs over HTTP. `build-pxe-initramfs.sh` derives a
  PXE initramfs with a bounded `nlplug-findfs` wait.

## Testing and validation

There are **no unit tests** — this is an integration repo. Validation is
artifact verification + QEMU boot tests + hardware results:

```bash
bash scripts/verify-build.sh                              # E1 artifacts+checksums, E2 GPT/fsck, E3 PXE
bash scripts/test-disk-image-qemu.sh [out/….img.zst]      # serial boot-marker test (PASS/FAIL/INCONCLUSIVE)
bash scripts/test-iso-qemu.sh [out/….iso]                 # interactive serial console (Ctrl-A X to exit)
```

- `verify-build.sh` checks artifact existence/size (Alpine ≤ 1536 MiB, Arch
  ≤ 2048 MiB compressed), SHA-256, GPT integrity (`sgdisk -v`), ESP/root
  filesystems (`fsck`), and PXE publication state.
- `test-disk-image-qemu.sh` boots the image in QEMU/OVMF (KVM when available,
  else TCG), patches the loader entry for serial console, and greps the serial
  log for ordered success/failure boot markers (compositor, seatd, dbus, sshd,
  firstboot; kernel panic / root mount failures).
- Validation matrix (`docs/validation.md`): documentation-only → link/consistency
  check; image/package/bootloader/overlay → `verify-build.sh` + both QEMU tests;
  service-order/first-frame → QEMU + measured first-frame time; GPU/input/
  firmware/device-profile → QEMU + **ROG Ally hardware result**.
- Record with every image change: pinned distro tag and repos, aports revision,
  artifact digest, QEMU result, first-frame timestamp and renderer, kernel /
  Mesa / firmware / wlroots versions, hardware result when applicable.
- CI (`.github/workflows/ci.yml`, GitHub Actions on `ubuntu-24.04`, PRs to
  `main` + nightly): build → `verify-build.sh` → QEMU boot test, uploading
  build log, disk image, ISO, and QEMU serial log as artifacts.

## Code style and conventions

- All scripts are Bash with `set -euo pipefail` and a descriptive header comment
  (purpose, usage, env vars). Inner/nspawn scripts must tolerate running
  standalone (`PLAYOS_ROOT` defaults to `/workspace`).
- **Logging:** host-side scripts source `shared/logging.sh`; nspawn-inner and
  standalone scripts source `shared/logging-helpers.sh` and use `_log_step` /
  `_log_info` / `_log_warn` / `_log_error` / `_log_success` (falls back to plain
  `echo` when no log directory exists). Replace raw `echo "==>"` / `WARNING:`
  patterns with these helpers when touching a script.
- **Logs:** every run writes `logs/YYYY-MM-DD_HH-MM-SS--<distro>-<version>--<arch>/`
  (`summary.log`, per-script logs, `metadata.json`) with a `logs/latest`
  symlink. The orchestrator passes `PLAYOS_LOG_DIR`/`PLAYOS_LOG_LEVEL` into
  nspawn via `--setenv`.
- **bash EXIT trap warning:** bash supports only one EXIT trap — the last one
  wins. Merge cleanup + `close_logging` into a single combined trap function
  (see `build-iso-ubuntu.sh`).
- **Package inventory:** when changing the Alpine package set, keep
  `alpine/mkimg.playos.sh` (apks), `alpine/genapkovl-playos.sh` (world),
  `alpine/packages.x86_64`, and `scripts/build-disk-image-alpine.sh` aligned.
- **Documentation:** `docs/README.md` defines one canonical document per
  concern — update the relevant doc whenever image configuration, service
  order, build flow, or validation requirements change, and label planned
  behaviour as planned. Platform contracts go to `playos-spec`, not here.
- musl, not glibc, on the reference system: all Alpine binaries build against
  musl; never add host-wide glibc as an implicit base dependency (glibc-only
  games run through declared compatibility runtimes).

## Security considerations

- The `playos-debug` SSH public key embedded in the build scripts is
  **intentionally public** development access. Do not add real private keys,
  tokens, or user credentials to the repo; use `PLAYOS_SSH_PUBKEY` to inject
  your own public key at build time.
- `PLAYOS_WIFI_PSK` is written into a `0600` NetworkManager profile only when
  explicitly set at build time — treat it as a debug facility, never commit
  real PSKs.
- Supply-chain verification: the Alpine minirootfs SHA-256 is verified against
  the official published checksum; the aports patch is validated with
  `git apply --check` before application; every disk image ships with a
  `.sha256` that `verify-build.sh` re-checks. The Arch bootstrap tarball and
  CachyOS packages currently rely on version pinning + pacman keyring
  (`F3B607488DB35A47`) — see `docs/audit-findings.md` for known asymmetries.
- ISO builds generate a local `abuild` signing key inside the throwaway nspawn
  container solely for APKINDEX signing; no long-lived signing keys are stored
  in the repo.
- Known-issue tracking lives in `docs/audit-findings.md` (status-tagged
  findings) — check it before and after changing the build pipeline.

## Where things go (decision guide)

| Change | Location |
|---|---|
| Alpine ISO package set / mkimage profile | `alpine/mkimg.playos.sh`, `alpine/genapkovl-playos.sh` |
| Alpine installed-image population | `scripts/build-disk-image-alpine.sh` |
| Arch installed-image population | `scripts/build-disk-image-arch.sh`, `arch/packages*.x86_64` |
| Boot/service behaviour (Alpine) | `alpine/init.d/` (OpenRC) |
| Boot/service behaviour (Arch) | `arch/systemd/` |
| First-boot logic | `alpine/init.d/playos-firstboot` + `shared/firstboot-common.sh` (keep in sync) |
| Partition layout, bootloader, fstab, profiles | `shared/` |
| Orchestration, distro dispatch, compression, PXE deploy | `scripts/build-iso-ubuntu.sh` |
| PlayOS component versions/build flags | `scripts/build-playos-components.sh` |
| aports modifications | `patches/aports-mkimage.patch` (regenerate per `patches/README.md`) |
| Platform behaviour contracts | sibling repo `playos-spec` (never here) |
| Compositor/shell/API source changes | sibling repos `playos-runtime`, `playos-shell`, `playos-platform-api` |
