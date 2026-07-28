# AGENTS.md — playos-refdistro

> **⚠️ FIRST:** Read [`gen-context.md`](gen-context.md) before anything else to understand the full PlayOS platform context.

## Purpose

This repository builds the Alpine-based PlayOS reference operating system for full Runtime Devices.

## Source of truth

Platform behaviour is specified in `playos-spec`. ADR-0004 selects Alpine Linux, musl, apk, OpenRC, and Alpine mkimage tooling for the reference OS. Distribution details must not leak into the public PlayOS API.

## Golden rules

1. **First frame first.** Only GPU/input readiness, seatd, compositor, and shell belong on the visual path.
2. **Use Alpine-native mechanisms.** New work uses apk, OpenRC, aports, mkimage, initramfs, modloop, and supported Alpine persistence patterns.
3. **Pin releases.** Released images use a pinned Alpine stable branch. Do not consume unpinned edge repositories.
4. **Support multiple distro backends.** Alpine is the reference. Arch + CachyOS
   is an alternative backend for optimized handheld and desktop builds. Both
   produce identical output formats: compressed GPT disk images + bootable ISOs.
   Distro-specific code lives in `alpine/` or `arch/`; shared logic in `shared/`.
5. **Keep runtime code distribution-independent.** Package/init/image code belongs here. Runtime and shell sources must build on musl without depending on apk or OpenRC APIs.
6. **VMs and hardware boot.** Image builds do not validate DRM/KMS, input,
   suspend, or firmware.
7. **No secrets or host-specific paths.**

## Primary workflow

```text
# Alpine (reference)
bash scripts/build-iso-ubuntu.sh

# Arch + CachyOS (general optimized)
PLAYOS_DISTRO=arch PLAYOS_KERNEL_VARIANT=cachyos bash scripts/build-iso-ubuntu.sh

# Arch + CachyOS (handheld optimized — ROG Ally, Steam Deck)
PLAYOS_DISTRO=arch PLAYOS_KERNEL_VARIANT=deckify bash scripts/build-iso-ubuntu.sh
```

Each pipeline: Ubuntu wrapper → pinned build root → distro-specific image
tooling → compressed GPT disk image + bootable ISO → QEMU/OVMF smoke test.

## Layout policy

- `alpine/`: authoritative profile, package lists, overlays, and image configuration.
- `arch/`: Arch Linux profile — packages, pacman.conf (pinned + CachyOS repos), mkinitcpio.conf, systemd units.
- `shared/`: distro-agnostic code (partition layout, bootloader install, fstab, device profiles, firstboot).
- `scripts/build-alpine-iso.sh`: shared image entrypoint.
- `docs/README.md`: canonical documentation index.
- `docs/build/ubuntu.md`: Ubuntu host workflow.
- `docs/architecture/`: image-pipeline and boot/service architecture.
- `docs/validation.md`: required validation evidence.

A future distro backend must be proposed separately and own its package recipes, image tooling, init/service definitions, tests, and release lifecycle. It must not share mutable implementation state with the Alpine profile.

## Service policy

OpenRC is the reference init system.

- `playos-visual` contains only the first-frame path.
- `playos-async` is reserved for audio, networking, Bluetooth, library,
  updates, cloud, marketplace, telemetry, and debug services after compositor
  readiness.
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

See [`docs/validation.md`](docs/validation.md) for the validation matrix.
