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
5. **Publication.** The wrapper fixes output ownership and deploys the ISO,
   boot files, APK cache, and disk image to the local PXE directory.

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

## Installation model

PlayOS installs the pre-built compressed disk image. The Shell's integrated
installer writes that image and first boot performs device-specific identity
initialization: machine ID, filesystem UUIDs, fstab, and EFI boot entry.

See [Boot and services](boot-and-services.md) for runtime startup behavior.
