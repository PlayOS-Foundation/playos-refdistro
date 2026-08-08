# AGENTS.md — playos-refdistro

> **Implementation status:** 🟢 Sprint 0 Complete — All 10 Sprint 0 tasks done. Build infrastructure fully set up: `br2-external/` skeleton with 5 package stubs, QEMU x86_64 defconfig, BusyBox initramfs `/init` script, UEFI boot checker, developer `Makefile`, `versions.lock` with real SHAs, CI pipeline (`.github/workflows/qemu-build.yml`), `setup-ubuntu.sh`, and `playos_log.sh` logging framework. Ready for Sprint 1 (playos-init).

This repository is the **reference distribution** — the Buildroot `br2-external` tree that assembles all PlayOS components into a bootable, immutable system image for the ASUS ROG Ally (and QEMU for development). This is where the OS image is built; no C code lives here.

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
br2-external/
├── external.desc               ← br2-external name and description
├── Config.in                   ← Top-level Kconfig menu
├── external.mk                 ← Includes all package .mk files
├── configs/
│   ├── playos_qemu_x86_64_defconfig   ← QEMU dev target
│   └── playos_ally_defconfig          ← ROG Ally production target
├── package/
│   ├── playos-init/
│   │   ├── playos-init.mk
│   │   └── Config.in
│   ├── playos-compositor/
│   │   ├── playos-compositor.mk
│   │   └── Config.in
│   ├── playos-shell/
│   │   ├── playos-shell.mk
│   │   └── Config.in
│   ├── playos-platform-api/
│   │   ├── playos-platform-api.mk
│   │   └── Config.in
│   └── wlroots/
│       ├── wlroots.mk
│       └── Config.in
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

## Make Targets

```sh
make setup          # Clone Buildroot, apply br2-external, check deps
make qemu-config    # Open menuconfig for QEMU target
make qemu-build     # Full image build for QEMU (slow first time, ~40 min)
make qemu-run       # Boot image in QEMU/OVMF
make ally-config    # Open menuconfig for ROG Ally target
make ally-build     # Full image build for ROG Ally
make ally-flash     # Flash image to USB drive (prompts for device)
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
# Component               Git SHA (40 chars)        Tag / branch hint
BUILDROOT_SHA=            <sha>                     # buildroot-YYYY.MM
LINUX_SHA=                <sha>                     # linux-6.x.y
WLROOTS_SHA=              <sha>                     # v0.x.y
PLAYOS_INIT_SHA=          <sha>                     # from playos-init main
PLAYOS_COMPOSITOR_SHA=    <sha>                     # from playos-compositor main
PLAYOS_SHELL_SHA=         <sha>                     # from playos-shell main
PLAYOS_PLATFORM_API_SHA=  <sha>                     # from playos-platform-api main
```

All SHAs must be filled before tagging a release. CI will fail on empty values.

## Partition Layout (do not change without ADR)

| Partition | Label | Size | Writable |
|---|---|---|---|
| EFI System | ESP | 256 MB | No |
| System A | `playos-a` | 2 GB | No (immutable) |
| System B | `playos-b` | 2 GB | No (immutable) |
| Data | `playos-data` | remainder | Yes |

`/data` is bind-mounted to `/home/playos-game/saves`, `/etc/playos/user/`, and the game library.

## What NOT to Do

- **Do not add C source code here** — all source lives in the component repos.
- **Do not commit build output** (`output/`, `dl/` except for the lock file) — `.gitignore` covers this.
- **Do not hardcode `/dev/dri/card0`** anywhere — GPU discovery is done by `playos-init` via PCI enumeration (ADR-0008).
- **Do not add BusyBox applets to the production `ally` defconfig** — production image has no shell, no SSH, no debug tools (see `security-model.md`). BusyBox is allowed in the `qemu` defconfig for dev convenience.
- **Do not change the partition layout** without an ADR — the A/B update engine depends on it.
- **Linux environment required** — Buildroot does not run on Windows or macOS. Use WSL2, a Linux VM, or a dedicated Linux machine.
