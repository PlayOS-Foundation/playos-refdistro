# AGENTS.md — playos-refdistro

> **Implementation status:** 🟡 Sprints 0-7 Integrated; Sprint 10 installer wired — Build infrastructure complete. Packaged components: `playos-init`, `playos-compositor` (v0.4.0), `playos-platform-api` (0.3.0), `playos-shell` (Sprint 5.5), the trusted in-game overlay (`playos-overlay`, Sprint 7, built from `src/playos-overlay/`), and the standalone installer (`playos-installer`, Sprint 10, built from `src/playos-installer/`). wlroots 0.20 is versioned by the pinned Buildroot snapshot. Ally, installer, and QEMU defconfigs are provided. IPC sources live in the `playos-init` repo (cloned to `src/playos-init/ipc/` by `make setup`).

This repository is the **reference distribution** — the Buildroot `br2-external` tree that assembles all PlayOS components into a bootable, immutable system image for the ASUS ROG Ally (and QEMU for development). This is where the OS image is built. With two deliberate exceptions, no C code lives here: the trusted in-game overlay client (`src/playos-overlay/`, Sprint 7) and the standalone installer (`src/playos-installer/`, Sprint 10) are reference-distro-specific and are built from source in this repo.

## Specification Reference

Before touching any file here, read:
- [`playos-spec/src/build-guide.md`](https://github.com/PlayOS-Foundation/playos-spec/blob/main/src/build-guide.md) — Buildroot setup, br2-external layout, full make command reference
- [`playos-spec/src/kernel-config.md`](https://github.com/PlayOS-Foundation/playos-spec/blob/main/src/kernel-config.md) — kernel kconfig reference for AMD and Intel targets
- [`playos-spec/src/dev-environment.md`](https://github.com/PlayOS-Foundation/playos-spec/blob/main/src/dev-environment.md) — QEMU dev workflow, USB boot, env vars
- [`playos-spec/src/Sprint-0.md`](https://github.com/PlayOS-Foundation/playos-spec/blob/main/src/sprints/Sprint-0.md) — Sprint 0 exit criteria (what "bootable" means)

## Repository Layout

```
Makefile                        ← Developer command surface (make setup / qemu-build / etc.)
versions.lock                   ← Pinned commit SHAs for all components
src/
└── playos-installer/           ← Sprint 10 installer C source (in-repo exception)
scripts/
├── gen-ally-usb-image.sh       ← ROG Ally live+installer USB image assembly (S13.7)
└── gen-intel-usb-image.sh      ← Intel live+installer USB image assembly (S13.7)
br2-external/
├── external.desc               ← br2-external name and description
├── Config.in                   ← Top-level Kconfig menu
├── external.mk                 ← Includes all package .mk files
├── configs/
│   ├── playos_qemu_x86_64_defconfig      ← QEMU dev target
│   ├── playos_ally_defconfig             ← ROG Ally dev target (live+installer)
│   ├── playos_ally_production_defconfig  ← ROG Ally prod target (no SSH)
│   └── playos_intel_pc_defconfig         ← Intel PC dev target (live+installer)
├── package/
│   ├── playos-init/
│   │   ├── playos-init.mk
│   │   └── Config.in
│   ├── playos-compositor/
│   │   ├── playos-compositor.mk   ← v0.4.0 (Sprint 4 DRM/KMS)
│   │   └── Config.in
│   ├── playos-shell/              ← Sprint 5.5 (packaged, v0.1.0)
│   │   ├── playos-shell.mk
│   │   └── Config.in
│   ├── playos-platform-api/
│   │   ├── playos-platform-api.mk
│   │   └── Config.in
│   ├── playos-installer/          ← Sprint 10 (in-repo source, libfdisk + raylib)
│   │   ├── playos-installer.mk
│   │   └── Config.in
│   └── wlroots/
│       ├── wlroots.mk             ← wlroots 0.20
├── board/
│   ├── common/
│   │   ├── rootfs-overlay/     ← Files overlaid onto the root filesystem
│   │   │   ├── etc/playos/     ← Runtime config files
│   │   │   └── usr/lib/systemd/← (if using systemd) or OpenRC scripts
│   │   └── post-image.sh       ← Image finalization script
│   ├── qemu/
│   │   └── grub.cfg
│   └── ally/
│       └── grub.cfg
└── linux/
    ├── playos-ally.config      ← Full kernel config (AMD target)
    └── playos-qemu.config      ← Full kernel config (QEMU/x86_64)
```

## Key Files

| File | Purpose |
|---|---|
| `Makefile` | All developer commands — start here |
| `versions.lock` | Pin file — all component Git SHAs must be locked here before a release |
| `br2-external/configs/playos_qemu_x86_64_defconfig` | QEMU build — use this for all dev work |
| `br2-external/configs/playos_ally_defconfig` | ROG Ally production build |
| `br2-external/board/common/rootfs-overlay/` | Files dropped verbatim onto the root fs |

### IPC Sources

IPC C sources (`ipc_client.c`, `ipc_server.c`, `lifecycle_fd.c`) live in the **playos-init repository** and are cloned to `src/playos-init/ipc/` by `make setup` — they are part of the `playos-init` build, not a standalone runtime library, and are not committed in this repository.

## Make Targets

```sh
make setup          # Clone Buildroot, apply br2-external, check deps
make qemu-config    # Open menuconfig for QEMU target
make qemu-build     # Full image build for QEMU (slow first time, ~40 min)
make qemu-run       # Boot image in QEMU/OVMF
make ally-config    # Open menuconfig for ROG Ally target
make ally-build     # Full image build for ROG Ally
make ally-dev-usb-image    # Consolidated dev live+installer USB image (SSH)
make ally-prod-usb-image   # Consolidated prod live+installer USB image (no SSH)
make ally-flash     # Flash dev image to USB drive (prompts for device)
make intel-dev-usb-image   # Intel dev live+installer USB image (SSH)
make clean          # Remove build output (keeps dl/ cache)
make distclean      # Remove everything including dl/
```

## Adding a New Package

1. Create `br2-external/package/PKGNAME/PKGNAME.mk` using Buildroot's `generic-package` or `cmake-package` infrastructure.
2. Create `br2-external/package/PKGNAME/Config.in` with a `BR2_PACKAGE_PKGNAME` bool.
3. Add `source "package/PKGNAME/Config.in"` to `br2-external/Config.in`.
4. Enable the package in the relevant defconfig: `make qemu-config`, find the package, save.
5. Add the component's Git SHA to `versions.lock`.

## versions.lock Format

```
# Component                Version/SHA (full 40-char commit)  Tag / branch hint
BUILDROOT_COMMIT=          <sha>                     # buildroot-YYYY.MM
LINUX_VERSION=             <version>                 # linux-6.x.y
LINUX_SHA256=              <sha256>                  # kernel.org tarball digest
WLROOTS_COMMIT=            <sha>                     # wlroots-0.20 (informational)
PLAYOS_SPEC_COMMIT=        <sha>                     # from playos-spec main
PLAYOS_PLATFORM_API_COMMIT=<sha>                     # from playos-platform-api main
PLAYOS_RUNTIME_COMMIT=     <sha>                     # from playos-runtime main
PLAYOS_INIT_COMMIT=        <sha>                     # from playos-init main
PLAYOS_COMPOSITOR_COMMIT=  <sha>                     # from playos-compositor main
PLAYOS_SHELL_COMMIT=       <sha>                     # from playos-shell main
PLAYOS_SAMPLES_COMMIT=     <sha>                     # from playos-samples main
```

All SHAs must be filled before tagging a release. CI will fail on empty values.

## Partition Layout (do not change without ADR)

Installed internal disk (5 partitions, created by the Sprint 10 installer):

| Partition | Label | Size | Filesystem | Writable |
|---|---|---|---|---|
| EFI System | `ESP` | 512 MiB | FAT32 | No |
| System A | `playos-a` | 4 GiB | EROFS/squashfs | No (immutable) |
| System B | `playos-b` | 4 GiB | EROFS/squashfs | No (immutable, empty until Sprint 11) |
| Misc | `misc` | 64 MiB | ext4 | A/B slot metadata |
| Data | `playos-data` | remainder | ext4 | Yes |

Live USB and installer USB keep the compact 3-partition layout (ESP, `playos-a` payload, `playos-data`); the installer USB's `playos-a` additionally carries `/rootfs.squashfs` and `/BOOTX64.EFI` as the install payload.

`/data` is bind-mounted to `/home/playos-game/saves`, `/etc/playos/user/`, and the game library.

## What NOT to Do

- **Do not add C source code here** — all source lives in the component repos. Exceptions: `src/playos-overlay/` holds the trusted in-game overlay client source (Sprint 7), and `src/playos-installer/` holds the standalone installer source (Sprint 10); both are reference-distro-specific and built here rather than as standalone component repos.
- **Do not commit build output** (`output/`, `dl/` except for the lock file) — `.gitignore` covers this.
- **Do not hardcode `/dev/dri/card0`** anywhere — GPU discovery is done by `playos-init` via PCI enumeration (ADR-0008).
- **Do not add BusyBox applets to the production `ally` defconfig** — production image has no shell, no SSH, no debug tools (see `security-model.md`). BusyBox is currently present in the dev/installer `ally` defconfig (Sprint 11.6); the *production* defconfig (Sprint 12) must exclude it. Note `playos-init`, not BusyBox, is PID 1.
- **Do not change the partition layout** without an ADR — the A/B update engine depends on it.
- **Linux environment required** — Buildroot does not run on Windows or macOS. Use WSL2, a Linux VM, or a dedicated Linux machine.
