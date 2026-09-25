#!/bin/sh
# build-emulator.sh — run a device-profile PlayOS game in the QEMU emulator.
#
# The device artifact is a musl binary, so there is no emulator-specific build: only
# delivery. This script packages the game into an overlay initramfs and boots the
# QEMU image with it through scripts/qemu-boot-check.sh, so the guest boots exactly
# the same way as every other boot check.
#
# Why the emulator profile is worth having: once the game is running in the guest,
# its rendering and input are the *real* device stack's - a Wayland compositor on
# DRM, reading evdev - rather than a desktop shim. That is the high-fidelity path
# this profile exists for.
#
# Known limitation, deliberately left visible: the overlay makes the game present in
# the guest (usr/share/playos/emulator/game), but nothing launches it yet. The shell
# lists games from /data/games/<id>/, so making it launchable means staging it onto
# the data image with a manifest - the next increment, not something this script
# pretends to do.
#
# Usage:
#   ./build-emulator.sh <device-build-dir> [qemu-image-dir]
#
# Env:
#   PLAYOS_EMULATOR_PREPARE_ONLY=1   build and verify the overlay, do not boot
#   PLAYOS_EMULATOR_TIMEOUT=120      boot-check timeout in seconds
set -eu

DEVICE_BUILD="${1:?usage: build-emulator.sh <device-build-dir> [qemu-image-dir]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_DIR="${2:-$HERE/../output/qemu/images}"

GAME=""
for candidate in "$DEVICE_BUILD" "$DEVICE_BUILD/bin/game" "$DEVICE_BUILD/game"; do
    [ -f "$candidate" ] && [ -x "$candidate" ] && GAME="$candidate" && break
done
if [ -z "$GAME" ]; then
    echo "error: no game binary under $DEVICE_BUILD (build the device profile first:" >&2
    echo "       PLAYOS_SDK=.../playos-sdk ./sdk/scripts/build-device.sh <sample> $DEVICE_BUILD)" >&2
    exit 1
fi

# The guest cannot run a glibc binary, and a silent failure here would look like an
# emulator bug rather than a wrong artifact.
if ! file "$GAME" | grep -q "ld-musl"; then
    echo "error: $GAME is not a musl binary - build it with the device profile" >&2
    file "$GAME" >&2
    exit 1
fi

for f in "$IMG_DIR/bzImage" "$IMG_DIR/rootfs.cpio"; do
    [ -f "$f" ] || { echo "error: missing $f (run 'make qemu-build')" >&2; exit 1; }
done

echo "==> Emulator profile"
echo "    game:   $GAME"
echo "    image:  $IMG_DIR"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/usr/share/playos/emulator"
cp "$GAME" "$STAGE/usr/share/playos/emulator/game"

# Deterministic archive: sorted paths, fixed timestamps, so the same input gives the
# same overlay (useful when comparing runs).
OV="$STAGE/overlay.cpio"
( cd "$STAGE" && find usr -type f | LC_ALL=C sort | cpio -o -H newc --reproducible 2>/dev/null ) > "$OV"

# Verify the archive rather than trusting cpio's exit status: this is the delivery
# mechanism, and a silently empty overlay would look like a guest-side bug.
python3 - "$OV" <<'PY'
import sys
path = sys.argv[1]
found = []
with open(path, 'rb') as f:
    while True:
        hdr = f.read(110)
        if len(hdr) < 110 or not hdr.startswith(b'070701'):
            break
        def field(i):
            return int(hdr[6 + i * 8: 6 + i * 8 + 8], 16)
        size, namesz = field(6), field(11)
        name = f.read(namesz).rstrip(b'\0').decode()
        f.read((-(110 + namesz)) % 4)
        f.read(size)
        f.read((-size) % 4)
        found.append(name)
want = 'usr/share/playos/emulator/game'
if want not in found:
    print("error: the overlay does not contain " + want, file=sys.stderr)
    print("       contents: " + ", ".join(found), file=sys.stderr)
    sys.exit(1)
print("    overlay: %d entry(ies), verified %s (%d bytes)" % (len(found), want, __import__('os').path.getsize(path)))
PY

if [ "${PLAYOS_EMULATOR_PREPARE_ONLY:-0}" = "1" ]; then
    echo "==> Overlay prepared: $OV"
    echo "    (PLAYOS_EMULATOR_PREPARE_ONLY=1 - not booting)"
    exit 0
fi

echo "==> Booting the guest with the overlay (timeout ${PLAYOS_EMULATOR_TIMEOUT:-120}s)"
PLAYOS_BOOT_CHECK_INITRD_OVERLAY="$OV" \
TIMEOUT="${PLAYOS_EMULATOR_TIMEOUT:-120}" \\
    sh "$HERE/qemu-boot-check.sh" "$IMG_DIR"
echo "==> Emulator run finished - see the boot-check output above for the guest's state"
