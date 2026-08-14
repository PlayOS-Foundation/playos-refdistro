# PlayOS Reference Distribution

> Buildroot `br2-external` tree that assembles all PlayOS components into a bootable, immutable system image for the ASUS ROG Ally (and QEMU for development).

**Dependency position:** `playos-refdistro` packages and pins all runtime components. It may not redefine their public contracts. No C source lives here — component source is cloned into `src/` by `make setup` and pinned in `versions.lock`.

## What This Repository Owns

- Buildroot `br2-external` tree (`br2-external/`) — package definitions, defconfigs, board files, rootfs overlay
- Kernel configurations and patches for all supported targets
- Board-specific firmware, grub configs, and BusyBox/init config
- Image assembly and USB-flash scripts (`scripts/`)
- Hardware check helpers (`tools/hw-check/`)
- `versions.lock` — all component commit pins (single source of truth for reproducibility)
- A committed Buildroot package wrapper for Raylib (`src/playos-raylib/`)

## Quick Start

```bash
# Install host dependencies and clone/pin all components
make setup

# QEMU development build
make qemu-config
make qemu-build
make qemu-run

# ROG Ally production build → USB-bootable image
make ally-config
make ally-build
make ally-usb-image
make ally-flash
```

See [`playos-spec/build-guide.md`](https://github.com/PlayOS-Foundation/playos-spec/blob/main/build-guide.md) for full instructions.

## Make Targets

| Target | Description |
|---|---|
| `make setup` | Verify pins, clone Buildroot + component repos, apply `br2-external` |
| `make verify-pins` | Check all `versions.lock` pins are set |
| `make qemu-config` | Open menuconfig for the QEMU target |
| `make qemu-build` | Full image build for QEMU |
| `make qemu-run` | Boot the image in QEMU/OVMF |
| `make ally-config` | Open menuconfig for the ROG Ally target |
| `make ally-build` | Full image build for ROG Ally |
| `make ally-usb-image` | Produce a USB-bootable disk image |
| `make ally-flash` | Flash the image to a USB drive (prompts for device) |
| `make clean` | Remove build output (preserves `dl/` cache) |
| `make distclean` | Remove everything including `dl/` and `buildroot/` |

## Supported Targets

| Target | Defconfig | Status |
|---|---|---|
| QEMU x86_64 | `playos_qemu_x86_64_defconfig` | Primary development target |
| ROG Ally | `playos_ally_defconfig` | Primary hardware target |

## Packaged Components

The `br2-external` tree defines one package per PlayOS component (see `br2-external/package/`):

| Package | Purpose |
|---|---|
| `playos-init` | PID 1 process supervisor |
| `playos-compositor` | wlroots-based Wayland compositor |
| `playos-runtime` | Wayland protocol definitions |
| `playos-platform-api` | Public game/platform API (`libplayos`) |
| `playos-shell` | Game library shell (Raylib) |
| `playos-raylib` | Raylib 6.0 with the PlayOS Wayland/EGL/GLES2 backend |
| `playos-samples` | Shipped sample games |

## Repository Structure

```
buildroot/              Buildroot (pinned by BUILDROOT_COMMIT in versions.lock)
br2-external/
├── configs/            Target defconfigs (qemu, ally)
├── package/            One package dir per PlayOS component
├── board/              Board files: rootfs-overlay, grub.cfg, kernel configs, patches
├── Config.in           Top-level Kconfig menu
├── external.desc       br2-external name/description
└── external.mk         Includes all package .mk files
src/                    Cloned component sources (populated by make setup; gitignored)
├── playos-init/
├── playos-compositor/
├── playos-runtime/
├── playos-platform-api/
├── playos-shell/
├── playos-samples/
└── playos-raylib/      Committed Buildroot package wrapper (not a clone)
scripts/                Build/test/flash helper scripts
tools/hw-check/         Hardware check scripts (audio, display, input, power, storage)
docs/                   Extra documentation (firmware.md)
versions.lock           All component commit pins
```

## Version Pinning

`versions.lock` is the single source of truth for reproducibility. Every PlayOS component is pinned to a full commit SHA (never a branch), and the Buildroot snapshot is pinned via `BUILDROOT_COMMIT`. Third-party library versions (wlroots, Mesa, gcc, musl, …) are versioned transitively by the pinned Buildroot snapshot. CI fails on empty pins.

Validate the pins with:

```bash
make verify-pins   # runs scripts/verify-versions.sh
```
