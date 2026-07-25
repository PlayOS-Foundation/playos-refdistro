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

The primary developer workflow is a **native Ubuntu Server**.

Ubuntu uses `systemd-nspawn` to execute Alpine's own tooling inside a checksum-verified Alpine 3.24.1 minirootfs:

```text
Ubuntu Server
  → systemd-nspawn
  → official Alpine minirootfs
  → apk + abuild + aports + mkimage
  → out/*.iso
```

This is not a second distro implementation. Ubuntu only hosts the isolated Alpine build root.

## Native Ubuntu quick start

```bash
bash scripts/setup-ubuntu-build-host.sh
bash scripts/build-iso-ubuntu.sh
bash scripts/test-iso-qemu.sh
```

See the [documentation index](docs/README.md) for build, image-pipeline, boot,
and validation guidance.

The setup wrapper:

- installs `systemd-container`, QEMU, and OVMF on Ubuntu;
- downloads Alpine `alpine-minirootfs-3.24.1-x86_64.tar.gz`;
- verifies the official SHA-256 file;
- extracts it under `.build/alpine-rootfs/`;
- installs Alpine image-building dependencies with apk.

The build wrapper enters that root with `systemd-nspawn` and runs
`scripts/build-alpine-iso.sh`. It does not modify the server's PXE/network
configuration.

See [Build on Ubuntu Server](docs/build/ubuntu.md).

## Implementation status

- Alpine is the only active reference-distro profile.
- Image work belongs under `alpine/` and uses apk, aports, mkimage, and OpenRC.
- The retired Arch implementation remains recoverable from Git history.
- A future distro profile requires its own proposal, packaging, image, init, test, and release lifecycle.

The active Alpine profile, build policy, and implementation details are
documented in [`AGENTS.md`](AGENTS.md) and
[Image pipeline](docs/architecture/image-pipeline.md).

## Boot policy

```text
UEFI
  → Linux kernel and Alpine initramfs
  → OpenRC playos-visual
  → GPU/input readiness
  → seatd
  → playos-compositor
  → playos-shell first frame
  → asynchronous services after compositor readiness
```

Audio, network, Bluetooth, cloud, marketplace, updates, indexing, telemetry, and SSH must not block the first frame.

## Repository layout

```text
playos-refdistro/
├── alpine/
│   ├── mkimg.playos.sh
│   ├── genapkovl-playos.sh
│   └── packages.x86_64
├── scripts/
│   ├── setup-ubuntu-build-host.sh
│   ├── build-iso-ubuntu.sh
│   ├── test-iso-qemu.sh
│   ├── install-alpine-build-deps.sh
│   ├── build-alpine-iso.sh
├── docs/
└── out/
```

## Baseline validation

The Alpine baseline is accepted when it passes:

- reproducible ISO build from the pinned minirootfs;
- UEFI boot in headless QEMU/OVMF;
- compositor and shell compiled against musl;
- virtual renderer fallback;
- ROG Ally amdgpu rendering;
- controller, Home, touch, and 60/120 Hz;
- sample launch and return;
- persistent data;
- measured first-frame time.

The current image builds and bundles PlayOS binaries directly from sibling
checkouts. Release images should transition to musl-native signed APK
packaging.

See [Validation](docs/validation.md) for the required evidence by change type.

## Related repositories

- [playos-spec](https://github.com/PlayOS-Foundation/playos-spec)
- [playos-runtime](https://github.com/PlayOS-Foundation/playos-runtime)
- [playos-shell](https://github.com/PlayOS-Foundation/playos-shell)
- [playos-reference-devices](https://github.com/PlayOS-Foundation/playos-reference-devices)
