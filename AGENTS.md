# AGENTS.md — playos-refdistro

## Purpose

This repository builds the Alpine-based PlayOS reference operating system for full Runtime Devices.

## Source of truth

Platform behaviour is specified in `playos-spec`. ADR-0004 selects Alpine Linux, musl, apk, OpenRC, and Alpine mkimage tooling for the reference OS. Distribution details must not leak into the public PlayOS API.

## Golden rules

1. **First frame first.** Only GPU/input readiness, seatd, compositor, and shell belong on the visual path.
2. **Use Alpine-native mechanisms.** New work uses apk, OpenRC, aports, mkimage, initramfs, modloop, and supported Alpine persistence patterns.
3. **Pin releases.** Released images use a pinned Alpine stable branch. Do not consume unpinned edge repositories.
4. **Preserve the Arch evidence.** `archiso/` is legacy migration material until Alpine reaches hardware parity. Do not rewrite history or delete it casually.
5. **Keep runtime code distribution-independent.** Package/init/image code belongs here. Runtime and shell sources must build on musl without depending on apk or OpenRC APIs.
6. **Docker builds; VMs and hardware boot.** Container success does not validate DRM/KMS, input, suspend, or firmware.
7. **No secrets or host-specific paths.**

## Primary workflow

```text
PowerShell or shell wrapper
  → pinned Alpine builder container
  → aports/mkimage PlayOS profile
  → out/*.iso
  → QEMU/OVMF smoke test
  → VirtualBox compatibility test
  → ROG Ally hardware test
```

## Layout policy

- `alpine/`: authoritative profile, package lists, overlays, and image configuration.
- `docker/Dockerfile`: primary pinned Alpine builder.
- `scripts/build-iso-docker.sh`: primary image entrypoint.
- `archiso/` and Arch-named scripts: legacy only during migration.
- `docs/alpine-migration.md`: parity gates and retirement criteria.

## Service policy

OpenRC is the reference init system.

- `playos-visual` contains only the first-frame path.
- `playos-async` contains audio, networking, Bluetooth, library, updates, cloud, marketplace, telemetry, and debug services.
- A background service may wait for compositor readiness.
- The compositor must never wait for a background service.
- Long-running daemons should use OpenRC supervision and bounded readiness checks.

## Compatibility policy

Reference components build against musl. glibc-only games run through declared compatibility runtimes. Do not add host-wide glibc as an implicit base dependency.

## Validation

Every image change should record:

- pinned Alpine tag and repositories;
- image digest;
- VM boot result;
- first-frame timestamp;
- renderer;
- kernel, Mesa, firmware, and wlroots versions;
- hardware result when device-facing code changed.
