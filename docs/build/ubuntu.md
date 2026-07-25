# Build on Ubuntu Server

The primary build host is x86_64 Ubuntu Server. Ubuntu hosts a
checksum-verified Alpine minirootfs through `systemd-nspawn`; all image tooling
runs with Alpine's native `apk`, `abuild`, aports, and mkimage tools.

## Requirements

- Ubuntu Server on x86_64 with `sudo`;
- outbound HTTPS access to Alpine repositories and Alpine GitLab;
- sibling checkouts of `playos-platform-api`, `playos-runtime`,
  `playos-shell`, and `playos-samples`;
- sufficient space for `.build/`, aports, caches, and multi-gigabyte outputs;
- KVM access recommended for QEMU validation.

## Setup and build

```bash
bash scripts/setup-ubuntu-build-host.sh
bash scripts/build-iso-ubuntu.sh
```

The setup script installs Ubuntu host dependencies, downloads the pinned
Alpine minirootfs, verifies its published SHA-256 checksum, and initializes
`.build/alpine-rootfs/`. Its version marker prevents an Alpine release from
being silently overlaid onto another release.

The full build creates both artifacts:

```text
out/playos-gpt-v3.24-x86_64.img.zst
out/playos-gpt-v3.24-x86_64.img.zst.sha256
out/alpine-playos-*-x86_64.iso
```

The wrapper also publishes ISO contents and the compressed image to
`/var/www/html/playos/`; the host must permit that operation.

## Configuration

| Variable | Default |
|---|---|
| `PLAYOS_ALPINE_VERSION` | `3.24.1` |
| `PLAYOS_ALPINE_BRANCH` | `v3.24` |
| `PLAYOS_APORTS_BRANCH` | `3.24-stable` |
| `PLAYOS_ARCH` | `x86_64` |
| `PLAYOS_IMAGE_SIZE_MB` | `6144` |
| `PLAYOS_ESP_SIZE_MB` | `512` |
| `PLAYOS_ROOT_SIZE_MB` | `4096` |

The source locations may also be overridden with `PLAYOS_RUNTIME_SRC`,
`PLAYOS_SHELL_SRC`, `PLAYOS_PLATFORM_SRC`, and `PLAYOS_SAMPLES_SRC`.

```bash
PLAYOS_IMAGE_SIZE_MB=8192 \
PLAYOS_RUNTIME_SRC=/path/to/playos-runtime \
bash scripts/build-iso-ubuntu.sh
```

## Rebuild and clean

Re-running the build reuses the initialized Alpine rootfs and caches. To change
the pinned Alpine release, move the existing rootfs aside before setup:

```bash
mv .build/alpine-rootfs .build/alpine-rootfs.previous
bash scripts/setup-ubuntu-build-host.sh
```

Use `bash scripts/clean.sh` to remove output artifacts; it preserves `.build/`.

## Next

See [Image pipeline](../architecture/image-pipeline.md) for the build phases
and [Validation](../validation.md) before accepting an output.
