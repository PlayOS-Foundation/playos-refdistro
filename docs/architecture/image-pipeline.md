# Image pipeline

Both the installable disk image and the live ISO originate from the same
Alpine rootfs configuration. The Ubuntu wrapper coordinates host-only disk
operations with Alpine-native image generation in `systemd-nspawn`.

## Outputs

| Artifact | Purpose |
|---|---|
| `playos-gpt-v3.24-x86_64.img.zst` | Compressed installable GPT disk image |
| `alpine-playos-*-x86_64.iso` | Bootable live and recovery ISO |

The disk image has three partitions:

| Partition | Size | Contents |
|---|---:|---|
| ESP | 512 MiB by default | systemd-boot, kernel, initramfs |
| root | 4096 MiB by default | Alpine system and PlayOS binaries |
| data | remaining image capacity | `/data/games`, `/data/saves`, `/data/config` |

## Build phases

1. **Host image layout.** `build-iso-ubuntu.sh` creates the GPT image, formats
   it, mounts the partitions, and captures their UUIDs.
2. **Alpine build and population.** Inside nspawn,
   `build-playos-components.sh` builds the Platform API, Runtime/compositor,
   Shell, and samples against musl. `build-disk-image.sh` installs Alpine
   packages and copies the resulting binaries into the mounted rootfs.
3. **ESP installation.** The Ubuntu host copies the systemd-boot EFI binary,
   kernel, initramfs, and loader entry to the ESP because nspawn bind mounts do
   not propagate nested mounts.
4. **Compression and ISO generation.** A second nspawn invocation compresses
   the disk image, runs Alpine mkimage, and rebuilds the ISO from a saved
   staging tree to avoid the known xorriso/apkovl corruption path.
   Aports modifications are applied via a version-pinned `.patch` file
   (`patches/aports-mkimage.patch`) instead of fragile in-line `sed`
   commands.  If Alpine updates the aports scripts, `git apply` fails
   cleanly at build time so the patch can be regenerated.
5. **Publication.** The wrapper fixes output ownership and deploys the ISO,
   boot files, APK cache, and disk image to the local PXE directory.

### Compression ownership

The orchestrator (`build-iso-ubuntu.sh`) is the **sole owner** of zstd compression.
The distro-specific ISO scripts (`build-alpine-iso.sh`, `build-arch-iso.sh`) receive
the pre-compressed image and bundle it into the ISO — they do **not** compress anything.

| Step | Owner | Details |
|---|---|---|
| Raw disk image (`.img`) | `build-iso-ubuntu.sh` phases 0–2 | GPT image with ESP, root, and data partitions |
| zstd compression | `build-iso-ubuntu.sh` phase 3 | `zstd -f -T0 --rm -12` — multi-threaded, level 12, removes original |
| SHA-256 checksum | `build-iso-ubuntu.sh` phase 3 | `sha256sum` run against the `.img.zst` file |
| ISO bundling | `build-alpine-iso.sh` / `build-arch-iso.sh` | Copies the pre-compressed `.img.zst` into ISO staging (`cp "$DISK_IMAGE" "$STAGING/"`) |

**Filename convention:**
`playos-gpt-${DISTRO}-${VERSION_TAG}-${ARCH}.img` → compressed to
`playos-gpt-${DISTRO}-${VERSION_TAG}-${ARCH}.img.zst` with accompanying
`playos-gpt-${DISTRO}-${VERSION_TAG}-${ARCH}.img.zst.sha256`.

Why the orchestrator owns compression: the raw `.img` is several GB of zeroes
(up to `PLAYOS_IMAGE_SIZE_MB`, default 6144 MiB). Compressing it with `--rm`
immediately after the bootloader install frees host disk space. The ISO scripts
run later inside nspawn and expect the `.img.zst` to already exist — they
treat it as a read-only artifact to bundle.

## Authoritative inputs

| Path | Responsibility |
|---|---|
| `alpine/mkimg.playos.sh` | Alpine mkimage profile and ISO package set |
| `alpine/genapkovl-playos.sh` | Live-image overlay and runlevels |
| `alpine/init.d/playos-compositor` | Compositor OpenRC service |
| `alpine/init.d/playos-firstboot` | One-shot disk-image initialization |
| `scripts/build-playos-components.sh` | musl component build |
| `scripts/build-disk-image.sh` | installed rootfs population |
| `scripts/build-iso-ubuntu.sh` | end-to-end host orchestration |
| `patches/aports-mkimage.patch` | Alpine aports modifications (replaces sed injections) |
| `scripts/apply-aports-patches.sh` | Applies the aports patch via `git apply` |

## Installation model

PlayOS installs the pre-built compressed disk image. The Shell's integrated
installer writes that image and first boot performs device-specific identity
initialization: machine ID, filesystem UUIDs, fstab, and EFI boot entry.

See [Boot and services](boot-and-services.md) for runtime startup behavior.
