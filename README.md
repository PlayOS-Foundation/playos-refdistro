# playos-refdistro

Alpine-based reference operating-system image for PlayOS Runtime Devices.

The image is a console appliance: it boots directly into the PlayOS compositor and shell, then starts non-visual services asynchronously.

> Show the shell as soon as the display path is ready.

## Architecture

| Layer | Reference choice |
|---|---|
| Upstream | Alpine Linux 3.24 stable |
| C library | musl |
| Packages | apk + signed PlayOS APK repository |
| Init | OpenRC |
| Image tooling | Alpine aports + mkimage |
| Display | PlayOS compositor on wlroots/DRM/KMS |
| Shell | Raylib Wayland client |
| Persistence | Separate PlayOS data partition |
| First device | ASUS ROG Ally |

Alpine is an implementation detail of the reference OS, not part of the portable PlayOS API.

## Build hosts

The primary developer workflow is a **native Ubuntu Server without Docker**.

Ubuntu uses `systemd-nspawn` to execute Alpine's own tooling inside a checksum-verified Alpine 3.24.1 minirootfs:

```text
Ubuntu Server
  → systemd-nspawn
  → official Alpine minirootfs
  → apk + abuild + aports + mkimage
  → out/*.iso
```

This is not a second distro implementation. Ubuntu only hosts the isolated Alpine build root.

Docker remains an optional equivalent build environment for Windows/macOS and existing CI.

## Native Ubuntu quick start

```bash
git switch agent/adopt-alpine-reference-os

bash scripts/setup-ubuntu-build-host.sh
bash scripts/build-iso-ubuntu.sh
bash scripts/test-iso-qemu.sh
```

The setup wrapper:

- installs `systemd-container`, QEMU, and OVMF on Ubuntu;
- downloads Alpine `alpine-minirootfs-3.24.1-x86_64.tar.gz`;
- verifies the official SHA-256 file;
- extracts it under `.build/alpine-rootfs/`;
- installs Alpine image-building dependencies with apk.

The build wrapper enters that root with `systemd-nspawn` and runs `scripts/build-alpine-iso.sh`. It does not install Docker or modify the server's PXE/network configuration.

See [Native Ubuntu build](docs/ubuntu-native-build.md).

## Optional Docker build

```powershell
./scripts/docker-build-builder.ps1
./scripts/docker-build-iso.ps1
```

Both host workflows call the same Alpine build entrypoint and produce output in `out/`.

## Migration status

- `archiso/` remains as legacy regression evidence.
- New image work belongs under `alpine/`.
- Arch systemd, pacman, and EROFS workarounds must be revalidated rather than copied.
- Arch may leave the active tree only after Alpine reaches ROG Ally parity.

See [Alpine migration](docs/alpine-migration.md).

## Boot policy

```text
UEFI
  → Linux kernel and Alpine initramfs
  → OpenRC playos-visual
  → GPU/input readiness
  → seatd
  → playos-compositor
  → playos-shell first frame
  → playos-async
```

Audio, network, Bluetooth, cloud, marketplace, updates, indexing, telemetry, and SSH must not block the first frame.

## Repository layout

```text
playos-refdistro/
├── alpine/
│   ├── mkimg.playos.sh
│   ├── genapkovl-playos.sh
│   └── packages.x86_64
├── docker/
│   ├── Dockerfile
│   └── arch-legacy.Dockerfile
├── scripts/
│   ├── setup-ubuntu-build-host.sh
│   ├── build-iso-ubuntu.sh
│   ├── test-iso-qemu.sh
│   ├── install-alpine-build-deps.sh
│   ├── build-alpine-iso.sh
│   └── build-iso-docker.sh
├── archiso/
├── docs/
└── out/
```

## Baseline validation

The Alpine profile does not replace the Arch baseline until it passes:

- reproducible ISO build from the pinned minirootfs;
- UEFI boot in headless QEMU/OVMF;
- compositor and shell compiled against musl;
- virtual renderer fallback;
- ROG Ally amdgpu rendering;
- controller, Home, touch, and 60/120 Hz;
- sample launch and return;
- persistent data;
- measured first-frame time.

The initial ISO proves Alpine/OpenRC/device/seat bring-up. PlayOS binaries are added after musl-native APK packaging.

## Related repositories

- [playos-spec](https://github.com/PlayOS-Foundation/playos-spec)
- [playos-runtime](https://github.com/PlayOS-Foundation/playos-runtime)
- [playos-shell](https://github.com/PlayOS-Foundation/playos-shell)
- [playos-reference-devices](https://github.com/PlayOS-Foundation/playos-reference-devices)
