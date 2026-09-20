#!/bin/sh
# build-install-kernel.sh — build the installed-path kernel (S14-P1)
#
# The Ally has no bootloader: the command line is compiled into the kernel, and
# init must know at boot whether it is running the live/installer medium or an
# installed system. That cannot be measured at runtime - at the pivot decision
# the USB stick does not exist yet (the dock's hub chain means its device node,
# interface and block device all appear together at ~4.1 s, while init decides at
# ~2.1 s), and the firmware reports the same BootCurrent = 0x0006 for a stick boot
# and an installed boot with the stick removed. So each image declares itself:
#
#   live image kernel        playos.live=1
#   installed-path kernel    playos.installed=1
#
# This builds the second from the same tree: it edits the kernel .config inside
# the build directory (Buildroot's linux-rebuild keeps it, unlike
# linux-reconfigure, which would copy the board config over it), then restores the
# live configuration and rebuilds it, so output/<board>/images/bzImage is the live
# kernel again and the generator can stage both.
#
# Freshness: the installed-path kernel is rebuilt whenever the live kernel is
# newer than it, so any build that recompiled the kernel regenerates both. Set
# FORCE=1 to rebuild unconditionally.
#
# Usage: scripts/build-install-kernel.sh [board]        (default: ally)
set -e

BOARD=${1:-ally}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/output/$BOARD"
IMAGES="$OUT/images"
BUILDROOT="$ROOT/buildroot"
CONFIG=$(ls -d "$OUT"/build/linux-*/.config 2>/dev/null | head -1)

[ -n "$CONFIG" ] || { echo "build-install-kernel: no $OUT/build/linux-*/.config" >&2; exit 1; }
grep -q 'CONFIG_CMDLINE=' "$CONFIG" || { echo "build-install-kernel: $CONFIG has no CONFIG_CMDLINE" >&2; exit 1; }
[ -f "$IMAGES/bzImage" ] || { echo "build-install-kernel: $IMAGES/bzImage missing" >&2; exit 1; }

if [ -z "$FORCE" ] && [ -f "$IMAGES/bzImage.install" ] &&
   [ "$IMAGES/bzImage.install" -nt "$IMAGES/bzImage" ]; then
    echo "==> installed-path kernel is up to date ($(basename "$IMAGES/bzImage.install"))"
    exit 0
fi

if grep -q 'playos\.live=1' "$CONFIG"; then
    echo "==> 1/2 building the installed-path kernel (playos.installed=1)"
    cp "$CONFIG" "$CONFIG.saved"
    sed -i 's/playos\.live=1/playos.installed=1/' "$CONFIG"
else
    echo "==> 1/2 building the installed-path kernel (adding playos.installed=1)"
    cp "$CONFIG" "$CONFIG.saved"
    sed -i 's/\(CONFIG_CMDLINE="[^"]*\)"/\1 playos.installed=1"/' "$CONFIG"
fi
grep -q 'playos\.installed=1' "$CONFIG" || { echo "build-install-kernel: could not set playos.installed=1" >&2; cp "$CONFIG.saved" "$CONFIG"; exit 1; }

make -C "$BUILDROOT" BR2_EXTERNAL="$ROOT/br2-external" O="$OUT" linux-rebuild >/dev/null
cp "$IMAGES/bzImage" "$IMAGES/bzImage.install"
echo "    -> bzImage.install ($(stat -c %s "$IMAGES/bzImage.install") bytes)"

echo "==> 2/2 restoring the live kernel (playos.live=1)"
sed -i 's/playos\.installed=1/playos.live=1/' "$CONFIG.saved"
grep -q 'playos\.live=1' "$CONFIG.saved" ||
    sed -i 's/\(CONFIG_CMDLINE="[^"]*\)"/\1 playos.live=1"/' "$CONFIG.saved"
cp "$CONFIG.saved" "$CONFIG"
rm -f "$CONFIG.saved"
make -C "$BUILDROOT" BR2_EXTERNAL="$ROOT/br2-external" O="$OUT" linux-rebuild >/dev/null
echo "    -> bzImage (live, $(stat -c %s "$IMAGES/bzImage") bytes)"
echo "==> done: bzImage declares playos.live=1, bzImage.install declares playos.installed=1"
