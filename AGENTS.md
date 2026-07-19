# AGENTS.md — playos-refdistro

## Purpose

This repository builds the Alpine-based PlayOS reference operating system for full Runtime Devices.

## Source of truth

Platform behaviour is specified in `playos-spec`. ADR-0004 selects Alpine Linux, musl, apk, OpenRC, and Alpine mkimage tooling for the reference OS. Distribution details must not leak into the public PlayOS API.

## Golden rules

1. **First frame first.** Only GPU/input readiness, seatd, compositor, and shell belong on the visual path.
2. **Use Alpine-native mechanisms.** New work uses apk, OpenRC, aports, mkimage, initramfs, modloop, and supported Alpine persistence patterns.
3. **Pin releases.** Released images use a pinned Alpine stable branch. Do not consume unpinned edge repositories.
4. **Keep one active distro implementation.** Alpine is the only supported profile. The retired Arch implementation is preserved in Git history, not in the active tree.
5. **Keep runtime code distribution-independent.** Package/init/image code belongs here. Runtime and shell sources must build on musl without depending on apk or OpenRC APIs.
6. **Docker builds; VMs and hardware boot.** Container success does not validate DRM/KMS, input, suspend, or firmware.
7. **No secrets or host-specific paths.**

## Primary workflow

```text
Ubuntu wrapper or optional container wrapper
  → pinned Alpine build root
  → aports/mkimage PlayOS profile
  → out/*.iso
  → QEMU/OVMF smoke test
  → VirtualBox compatibility test
  → ROG Ally hardware test
```

## Layout policy

- `alpine/`: authoritative profile, package lists, overlays, and image configuration.
- `docker/Dockerfile`: optional pinned Alpine builder.
- `scripts/build-alpine-iso.sh`: shared image entrypoint.
- `docs/alpine-migration.md`: Alpine bring-up and parity gates.

A future distro backend must be proposed separately and own its package recipes, image tooling, init/service definitions, tests, and release lifecycle. It must not share mutable implementation state with the Alpine profile.

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
