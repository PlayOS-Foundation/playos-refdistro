# PlayOS Reference Distribution

> Buildroot integration, kernel and initramfs configuration, `playos-init`, image assembly, installer, recovery, and release pinning.

**Dependency position:** `playos-refdistro` packages and pins all runtime components. It may not redefine their public contracts.

## What This Repository Owns

- `playos-init` — PID 1, process supervisor
- Buildroot `br2-external` tree
- Kernel configurations for all supported targets
- Board-specific firmware and rootfs overlays
- Package definitions for all PlayOS components
- Image assembly scripts and release pipeline
- Installer UI (`src/installer/`)
- Developer tools (`src/tools/playos-ctl`)
- `versions.lock` — all component pins

## Quick Start

```bash
# Install host dependencies
make setup

# QEMU development build
make qemu-config
make qemu-build
make qemu-run

# ROG Ally build
make ally-config
make ally-build
make ally-usb-image
```

See [`playos-spec/build-guide.md`](https://github.com/your-org/playos-spec/blob/main/build-guide.md) for full instructions.

## Supported Targets

| Target | Config | Status |
|---|---|---|
| QEMU x86_64 | `playos_qemu_x86_64_defconfig` | Primary development target |
| ROG Ally | `playos_rog_ally_defconfig` | Primary hardware target |
| Intel PC | `playos_intel_pc_defconfig` | Sprint 13 |

## Repository Structure

```
buildroot/              Buildroot (pinned submodule)
br2-external/           PlayOS Buildroot extension
src/playos-init/        PID 1 source
src/installer/          Installer UI source
src/tools/              Developer tools (playos-ctl)
scripts/                Build and test helper scripts
versions.lock           All component commit pins
```
