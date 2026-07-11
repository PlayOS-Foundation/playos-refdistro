# playos-refdistro

Minimal Arch-based reference distribution for PlayOS Runtime Devices.

Builds a fast-booting console-style Linux image that starts the PlayOS
compositor and shell first, then loads audio, network, Bluetooth, and other
services asynchronously.

## Philosophy

```
Show the shell as soon as the display path is ready.
Do not wait for network, Bluetooth, audio, cloud, updates, or library indexing.
```

## Boot budget

| Time | What |
|------|------|
| 0.0 s | UEFI → kernel |
| 0.5 s | kernel → systemd → playos-visual.target |
| 1.0 s | seatd starts |
| 1.5 s | playos-compositor starts (DRM/KMS takeover) |
| 2.0 s | **first shell frame visible** |
| 2.0 s+ | audio, network, Bluetooth, library, updates start async |

## Current state (v0.2)

- ✅ ISO boots to PlayOS visual target
- ✅ wlroots compositor takes over display (DRM/KMS)
- ✅ Raylib shell UI appears with game library (doubled fonts, readable on TV/console)
- ✅ Keyboard navigation (arrows, Enter, Esc)
- ✅ Sample games launch and return to shell (hello-playos, space-invaders)
- ✅ SSH access (root, empty password)
- ✅ IP address shown in shell bottom-right
- ✅ GPU auto-detection — pixman for VMware/virtio, EGL/GLES2 for real hardware
- ✅ Battery level shown in shell (auto-detected via sysfs — ROG Ally confirmed)
- ✅ Overlay size 512 MB (BIOS + UEFI boot entries)
- ✅ ROG Ally — compositor + shell + games working, battery visible
- ⚠️ VMware: `WLR_RENDERER=pixman` set automatically (vmwgfx limitation)
- ⬚ Controller input — evdev backend present, end-to-end test pending
- ⬚ Audio — PipeWire installed, not yet wired through Platform API
- ⬚ Suspend/resume — not yet implemented

## Host requirements

- Windows, macOS, or Linux host
- Docker Desktop (ISO build) or native Arch Linux with archiso
- VMware Workstation / VirtualBox (UEFI boot test)
- Git
- VS Code

## Quick start

### Option A: Docker Desktop (Windows host)

```powershell
# 1. Build the Docker builder image
.\scripts\docker-build-builder.ps1

# 2. Initialize the Arch ISO profile (first time only)
docker run --rm -it --privileged `
  -v "${PWD}:/workspace" `
  playos-arch-builder `
  /workspace/scripts/init-archiso-profile.sh

# 3. Build the PlayOS ISO
.\scripts\docker-build-iso.ps1

# 4. Boot in VirtualBox (UEFI, attach out/*.iso)
```

### Option B: Native Arch Linux (VM or bare metal)

```bash
# 1. One-time setup
./scripts/setup-arch-build-host.sh

# 2. Initialize the Arch ISO profile (first time only)
./scripts/init-archiso-profile.sh

# 3. Build the ISO
./scripts/build-iso-vmware.sh

# 4. ISO at out/archlinux-baseline-*.iso
```

## Repository layout

```
playos-refdistro/
├── README.md
├── AGENTS.md
├── docker/
│   └── Dockerfile                  # Arch Linux builder image
├── scripts/
│   ├── init-archiso-profile.sh     # Copy Arch baseline archiso profile
│   ├── build-iso-docker.sh         # Run mkarchiso inside container
│   ├── docker-build-builder.ps1    # Build Docker image (PowerShell)
│   ├── docker-build-iso.ps1        # Build ISO (PowerShell)
│   └── clean.sh                    # Clean output directory
├── archiso/
│   └── profiles/
│       └── playos/                 # PlayOS archiso profile
│           ├── packages.x86_64     # Installed packages
│           ├── profiledef.sh       # Profile definition
│           ├── pacman.conf         # Pacman configuration
│           └── airootfs/           # Root filesystem overlay
│               ├── etc/
│               │   ├── systemd/system/   # PlayOS systemd units
│               │   ├── sysusers.d/       # playos user
│               │   └── tmpfiles.d/       # Runtime directories
│               └── usr/
│                   ├── bin/              # playos-compositor, playos-shell
│                   └── lib/playos/       # Async service scripts
├── docs/
│   ├── fast-boot.md
│   ├── service-order.md
│   ├── boot-budget.md
│   └── virtualbox-test.md
└── out/                            # Built ISOs (gitignored)
```

## Key systemd targets

| Target | Purpose |
|--------|---------|
| `playos-visual.target` | Default boot target — blocks until compositor + shell are ready |
| `playos-async.target` | Started after first shell frame — audio, network, Bluetooth, library, updates |

## Services

| Service | Priority | Slice |
|---------|----------|-------|
| `playos-compositor.service` | Critical (blocks boot) | `playos-ui.slice` |
| `playos-audio.service` | Async | `playos-background.slice` |
| `playos-network.service` | Async | `playos-background.slice` |
| `playos-bluetooth.service` | Async | `playos-background.slice` |
| `playos-library.service` | Async (idle) | `playos-background.slice` |
| `playos-update.service` | Async (idle) | `playos-background.slice` |

## Slices (resource partitioning)

| Slice | CPU Weight | Purpose |
|-------|-----------|---------|
| `playos-ui.slice` | 10000 | Compositor, shell — highest priority |
| `playos-game.slice` | 8000 | Active game process |
| `playos-background.slice` | 100 | Async services — lowest priority |

## Kernel policy

| Phase | Kernel |
|-------|--------|
| Initial baseline | Stock Arch `linux` |
| Future gaming profile | CachyOS kernel (separate profile) |

## See also

- [PlayOS Book](https://github.com/PlayOS-Foundation/playos-spec) — specification and architecture
- [playos-runtime](https://github.com/PlayOS-Foundation/playos-runtime) — compositor and process launcher
- [playos-shell](https://github.com/PlayOS-Foundation/playos-shell) — reference console UI
- [ROG Ally bring-up](https://github.com/PlayOS-Foundation/playos-reference-devices) — device profile and setup scripts
