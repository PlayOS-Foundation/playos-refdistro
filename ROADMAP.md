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

1. **Migrate Raylib to 6.0 via custom APKBUILD.** Alpine 3.24 ships raylib
   5.0-r0 only. Create a custom `alpine/apkbuilds/raylib/APKBUILD` for 6.0,
   update soname references (`libraylib.so.450` → `libraylib.so.600`) in
   `genapkovl-playos.sh`, `build-disk-image.sh`, and `playos-installer`,
   then integrate the custom repo into `build-playos-components.sh`. Also
   update `playos-shell/gen-context.md` and `playos-spec` book chapter for
   the new version. See `mig2raylib6.md` for the full plan.
2. Build the existing ISO and disk image, then validate the artifacts and boot
   path in QEMU.
3. Record reproducible build inputs and validation evidence for that baseline
   image.
4. Complete ROG Ally hardware testing only after QEMU validation passes for
   device-facing changes.
5. Move non-visual services to a readiness-triggered `playos-async` path so
   networking, SSH, audio, Bluetooth, and background features cannot affect
   first-frame latency.
6. Replace direct binary copying with signed PlayOS APK packages built from
   pinned sources.

## Documentation

The current build, image, boot, and validation model is documented in
[`docs/README.md`](docs/README.md).
