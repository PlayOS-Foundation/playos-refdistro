#!/bin/bash
# erofs-fixup.sh — Work around mkfs.erofs file corruption
# The EROFS build process corrupts some small files (modules, firmware).
# We bundle known-good copies in the initramfs and bind-mount them here.
set -e

FIXUP_SRC="/run/fixup-firmware"
FIXUP_KO="$FIXUP_SRC/drm_exec.ko"
FIRMWARE_SRC="$FIXUP_SRC/amdgpu"
FIRMWARE_DST="/usr/lib/firmware/amdgpu"

# 1. Load fixed kernel module (drm_exec) if available
if [ -f "$FIXUP_KO" ]; then
    insmod "$FIXUP_KO" 2>/dev/null || true
    echo "erofs-fixup: loaded fixed drm_exec.ko"
fi

# 2. Bind-mount fixed firmware over corrupted EROFS firmware
if [ -d "$FIRMWARE_SRC" ] && [ "$(ls -A "$FIRMWARE_SRC" 2>/dev/null)" ]; then
    mount --bind "$FIRMWARE_SRC" "$FIRMWARE_DST" 2>/dev/null || true
    echo "erofs-fixup: bind-mounted fixed amdgpu firmware"
fi

exit 0
