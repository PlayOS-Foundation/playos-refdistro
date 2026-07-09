# AGENTS.md — playos-refdistro

Instructions for AI coding agents working in this repository.

## Repository purpose

This repository builds the minimal Arch-based PlayOS operating system image
for Runtime Devices. The build runs in Docker Desktop (Arch Linux container)
and produces bootable ISOs tested in VirtualBox.

## Golden rules

1. **The shell must appear first.** No service may block the first shell
   frame. Audio, network, Bluetooth, library scanning, and updates start
   asynchronously after `playos-compositor.service` is running.

2. **Docker is only the build environment.** Never treat Docker as a valid
   boot-test environment. Use VirtualBox for UEFI boot tests. Use real
   hardware for GPU/DRM/KMS, input latency, and handheld control validation.

3. **The compositor is the display owner.** `playos-compositor.service` runs
   as user `playos`, owns DRM/KMS, and manages all Wayland surfaces. The
   shell is a Wayland client, not the compositor.

4. **Systemd units must never depend on `network-online.target`,
   `NetworkManager-wait-online.service`, or `systemd-networkd-wait-online.service`.**
   These are unbounded delays that violate the boot budget.

5. **Placeholders are valid v0.1 artifacts.** The initial compositor and
   shell may be bash scripts that echo their status. Real C/C++/Raylib
   implementations come later. Do not delete working placeholders.

6. **Kernel policy: stock first.** The initial profile uses the stock Arch
   `linux` kernel. A CachyOS kernel profile is a separate future addition,
   not a replacement for the baseline.

## Repository conventions

- Shell scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, executable
- PowerShell scripts: `$ErrorActionPreference = "Stop"`
- Systemd units: `[Unit]`, `[Service]`, `[Install]` in standard order
- Package lists: one package per line, alphabetized within groups, comment
  block at top explaining the group
- Profile files: never edit Arch's baseline profile files directly unless
  the guide specifies a customization

## Build workflow

```
PowerShell scripts (host)
    → docker run (container)
        → bash scripts (container)
            → mkarchiso
                → out/*.iso
```

When adding a new build step:
- Add the container-side script under `scripts/` as a `.sh` file
- Add a PowerShell wrapper under `scripts/` as a `.ps1` file if it's a
  top-level developer command
- Document the step in this order: `README.md` quick start, then `docs/`

## Boot budget enforcement

The `playos-visual.target` boot chain must stay under 2 seconds:

```
UEFI → kernel → systemd → playos-visual.target
    → seatd.service
    → playos-compositor.service
        → /usr/bin/playos-compositor
        → /usr/bin/playos-shell (first frame)
```

Any new service added to the visual path must have a documented boot-time
cost in `docs/boot-budget.md`. Services that cannot meet the budget belong
in `playos-async.target`.

## Resource partitioning

All units MUST be assigned to a slice:

| Unit type | Slice |
|-----------|-------|
| Compositor, shell, UI | `playos-ui.slice` |
| Game process | `playos-game.slice` |
| Background services | `playos-background.slice` |

Do not create services without a `Slice=` directive.

## Symlinks on Windows

Systemd requires symlinks for `.wants/` directories and the default target.
Git on Windows may not preserve these. When creating symlinks, document the
exact `ln -sf` command and note that it must run inside a Linux container
or WSL. Never use Windows shortcuts or junctions for systemd symlinks.

## Testing

After each significant change:
1. `.\scripts\docker-build-iso.ps1` — must produce `out/*.iso`
2. Boot ISO in VirtualBox (UEFI mode) — must reach shell placeholder
3. Verify in the serial console that `playos-async.target` started

## See also

- `playos-arch-docker-agent-guide.md` in the workspace root — the full
  step-by-step implementation guide
- `../playos-spec/book/` — the PlayOS Book (architecture, compositor model,
  runtime architecture)
- `../playos-runtime/` — compositor source and process launcher
- `../playos-shell/` — reference shell source
