# copilot-instructions.md

PlayOS reference distribution builder. Docker-based Arch Linux ISO build via
archiso, boot-tested in VirtualBox.

## Purpose

Build a minimal Arch ISO that boots into the PlayOS compositor and shell as
fast as possible. Audio, network, Bluetooth, and other services start
asynchronously after the first shell frame.

## Key rules

- Docker is for builds only. VirtualBox is for boot tests. Real hardware
  (ROG Ally) is for GPU/input validation.
- The visual boot path must never wait for network, audio, or Bluetooth.
- All systemd units must have a `Slice=` directive.
- Use stock Arch `linux` kernel for the baseline. CachyOS is a separate
  future profile.
- Placeholder scripts in `/usr/bin/playos-compositor` and
  `/usr/bin/playos-shell` are valid v0.1 artifacts. Do not delete them.

## Build commands

```powershell
# Build the Docker image
.\scripts\docker-build-builder.ps1

# Initialize archiso profile (once)
docker run --rm -it --privileged -v "${PWD}:/workspace" playos-arch-builder /workspace/scripts/init-archiso-profile.sh

# Build the ISO
.\scripts\docker-build-iso.ps1

# Clean
.\scripts\clean.sh
```

## Directory conventions

- `docker/` — Dockerfile for the Arch builder image
- `scripts/` — build scripts (`.sh` for container, `.ps1` for host)
- `archiso/profiles/playos/` — the PlayOS archiso profile
- `archiso/profiles/playos/airootfs/` — root filesystem overlay (systemd
  units, users, scripts)
- `docs/` — architecture and testing documentation
- `out/` — built ISOs (gitignored, not committed)

## Systemd target order

```
playos-visual.target (default)
    → seatd.service
    → playos-compositor.service
        → playos-async.target (started async after compositor)
            → playos-audio.service
            → playos-network.service
            → playos-bluetooth.service
            → playos-library.service
            → playos-update.service
```

## Slices

- `playos-ui.slice` — CPUWeight=10000 (compositor, shell)
- `playos-game.slice` — CPUWeight=8000 (game processes)
- `playos-background.slice` — CPUWeight=100 (async services)

## References

- Full step-by-step guide: `playos-arch-docker-agent-guide.md` (workspace
  root)
- Spec: `../playos-spec/book/src/08-runtime-architecture/`
- Compositor source: `../playos-runtime/compositor/`
- Shell source: `../playos-shell/src/`
