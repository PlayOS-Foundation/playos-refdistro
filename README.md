# playos-refdistro

Alpine-based reference operating-system image for PlayOS Runtime Devices.

The image is a console appliance: it boots directly into the PlayOS compositor and shell, then starts audio, networking, Bluetooth, indexing, updates, and online services asynchronously.

> Show the shell as soon as the display path is ready.

## Architecture

| Layer | Reference choice |
|---|---|
| Upstream | Alpine Linux 3.24 stable branch |
| C library | musl |
| Packages | apk |
| Init | OpenRC |
| Image tooling | Alpine aports + mkimage |
| Display | PlayOS compositor on wlroots/DRM/KMS |
| Shell | Raylib Wayland client |
| Persistence | Separate PlayOS data partition |
| First device | ASUS ROG Ally |

Alpine is an implementation detail of the reference OS. It is not part of the portable PlayOS API.

## Migration status

The Alpine migration is in progress.

- The existing `archiso/` profile is preserved as a legacy regression reference.
- New image work belongs under `alpine/`.
- The primary builder is the pinned Alpine container.
- Arch-specific systemd units, pacman lists, and EROFS workarounds must not be copied into the Alpine design without revalidation.
- The Arch profile may be removed from the active tree only after Alpine reaches ROG Ally vertical-slice parity. Git history will remain intact.

See [`docs/alpine-migration.md`](docs/alpine-migration.md).

## Boot policy

```text
UEFI
  → Linux kernel and Alpine initramfs
  → OpenRC visual runlevel
  → GPU/input readiness
  → seatd
  → playos-compositor
  → playos-shell first frame
  → asynchronous PlayOS services
```

Audio, network, Bluetooth, cloud, marketplace, updates, library indexing, telemetry, and SSH must not block the first frame.

## Quick start

Prerequisites: Docker Desktop or Docker Engine, Git, and PowerShell 7 on Windows.

```powershell
./scripts/docker-build-builder.ps1
./scripts/docker-build-iso.ps1
```

The builder pins Alpine 3.24 and builds the `playos` mkimage profile. Output is written to `out/`.

The first migration milestone is a bootable Alpine ISO containing the package set and OpenRC overlay. The next milestone stages musl-built PlayOS binaries and reaches the interactive shell.

## Repository layout

```text
playos-refdistro/
├── alpine/
│   ├── mkimg.playos.sh          Alpine mkimage profile
│   ├── packages.x86_64          runtime package set
│   └── README.md                profile and overlay design
├── docker/
│   ├── Dockerfile               primary Alpine builder
│   └── arch-legacy.Dockerfile   historical Arch builder
├── scripts/
│   ├── build-iso-docker.sh      primary Alpine image build
│   ├── docker-build-builder.ps1
│   └── docker-build-iso.ps1
├── archiso/                     legacy Arch vertical slice
├── docs/
│   ├── alpine-migration.md
│   ├── fast-boot.md
│   └── boot-budget.md
└── out/
```

## Validation gates

The Alpine profile does not replace the working Arch baseline until it passes:

- reproducible ISO build from the pinned container;
- UEFI boot in QEMU/OVMF and VirtualBox;
- compositor and shell compiled against musl;
- virtual renderer fallback;
- ROG Ally amdgpu hardware rendering;
- built-in controller and Home;
- touch and 60/120 Hz modes;
- sample launch and return to shell;
- persistent data across reboot;
- measured first-frame boot time.

## Related repositories

- [playos-spec](https://github.com/PlayOS-Foundation/playos-spec)
- [playos-runtime](https://github.com/PlayOS-Foundation/playos-runtime)
- [playos-shell](https://github.com/PlayOS-Foundation/playos-shell)
- [playos-reference-devices](https://github.com/PlayOS-Foundation/playos-reference-devices)
