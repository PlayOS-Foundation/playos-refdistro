# Alpine image profile

This directory is the authoritative PlayOS reference-OS profile.

## Current milestone

The first profile builds a pinned Alpine 3.24 x86_64 ISO with:

- Linux LTS kernel and AMD firmware;
- Mesa EGL/GLES/GBM and RADV;
- Wayland, wlroots 0.19, libinput, and seatd;
- OpenRC `playos-visual` and `playos-async` runlevels;
- audio, network, Bluetooth, and SSH packages available on the image.

The build compiles the compositor and Shell against musl from sibling
checkouts and bundles them into the image. Signed PlayOS APK packaging remains
the next release-quality packaging milestone.

## Files

- `mkimg.playos.sh`: Alpine mkimage profile.
- `genapkovl-playos.sh`: diskless configuration and OpenRC runlevels.
- `packages.x86_64`: reviewable package inventory.

## Next packaging step

Create APKBUILD packages for:

- `playos-platform-api`;
- `playos-runtime` and `playos-compositor`;
- `playos-shell`;
- `playos-samples`;
- `playos-services` and device profiles.

The image profile should consume signed APKs from a PlayOS repository. It should not clone arbitrary Git heads during a release build.

See [Image pipeline](../docs/architecture/image-pipeline.md) for the current
build flow.

## Release rules

- Pin the Alpine stable branch and aports revision.
- Record repository URLs and image checksums.
- Do not use unpinned edge repositories.
- Keep background services out of `playos-visual`.
- Treat `apkovl` as development/recovery configuration, not the final system-update mechanism.
