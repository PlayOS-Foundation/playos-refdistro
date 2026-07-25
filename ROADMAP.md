# Roadmap

## Current baseline

- Alpine `v3.24` image tooling produces a compressed GPT disk image and a
  bootable ISO.
- Ubuntu uses a pinned Alpine minirootfs through `systemd-nspawn`.
- The build compiles sibling PlayOS components against musl and bundles the
  compositor, Shell, and samples.
- The disk image uses systemd-boot, a separate data partition, and one-shot
  first-boot initialization.

## Next milestones

1. Build the existing ISO and disk image, then validate the artifacts and boot
   path in QEMU.
2. Record reproducible build inputs and validation evidence for that baseline
   image.
3. Complete ROG Ally hardware testing only after QEMU validation passes for
   device-facing changes.
4. Move non-visual services to a readiness-triggered `playos-async` path so
   networking, SSH, audio, Bluetooth, and background features cannot affect
   first-frame latency.
5. Replace direct binary copying with signed PlayOS APK packages built from
   pinned sources.

## Documentation

The current build, image, boot, and validation model is documented in
[`docs/README.md`](docs/README.md).
