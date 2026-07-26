#!/usr/bin/env bash
# build-hid-asus-ally.sh — Build the hid-asus-ally out-of-tree kernel module
# for the ROG Ally and package it as a local Alpine APK.
#
# Runs inside the Alpine nspawn container. Requires linux-stable-dev
# for kernel headers.
set -euo pipefail

HID_VERSION="20240910"
HID_REPO="https://github.com/uejji/hid-asus-ally"
BUILD_DIR="${PLAYOS_BUILD_DIR:-/var/tmp/playos-build}"
APK_OUT="${PLAYOS_APK_OUT:-/var/tmp/playos-apks}"

echo "==> Building hid-asus-ally kernel module"

# Install kernel headers for the running kernel (linux-stable)
apk add --no-cache linux-stable-dev 2>&1 | tail -3

# Get kernel version string (e.g., "7.1.4-0-stable")
KERNEL_VER=$(ls /lib/modules/ | head -1)
echo "    Kernel version: $KERNEL_VER"

# Clone the driver source
HID_SRC="$BUILD_DIR/hid-asus-ally"
if [ ! -d "$HID_SRC" ]; then
    git clone --depth 1 "$HID_REPO" "$HID_SRC"
    # Tag 20240910 points to a non-commit object — check out commit directly.
    cd "$HID_SRC"
    git checkout 71648145e013a10771051304fcd110bab83ce9b4
else
    echo "    Using cached source at $HID_SRC"
fi

# Build the kernel module
echo "==> Compiling hid-asus-ally.ko"
make -C "$HID_SRC" \
    TARGET="$KERNEL_VER" \
    KERNEL_BUILD="/lib/modules/$KERNEL_VER/build" \
    -j"$(nproc)" modules

MODULE="$HID_SRC/hid-asus-ally.ko"
if [ ! -f "$MODULE" ]; then
    echo "error: module build failed — hid-asus-ally.ko not found" >&2
    exit 1
fi

# ── Package as APK ──────────────────────────────────────────────────
echo "==> Packaging hid-asus-ally-stable APK"
MODULE_SIZE=$(stat -c%s "$MODULE")

# Install path inside the APK: lib/modules/<kver>/kernel/drivers/hid/
INSTALL_PATH="lib/modules/$KERNEL_VER/kernel/drivers/hid/hid-asus-ally.ko"

PKG_DIR="$BUILD_DIR/apk-pkg"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/$(dirname "$INSTALL_PATH")"
cp "$MODULE" "$PKG_DIR/$INSTALL_PATH"

# .PKGINFO
cat > "$PKG_DIR/.PKGINFO" <<PKGINFO
pkgname = hid-asus-ally-stable
pkgver = ${HID_VERSION}-r0
arch = x86_64
size = ${MODULE_SIZE}
pkgdesc = HID driver for ROG Ally controller inputs (back paddles, gyro, special buttons)
url = ${HID_REPO}
license = GPL-2.0-only
depend = linux-stable
PKGINFO

# Create the .apk (gzip-compressed tar)
mkdir -p "$APK_OUT"
APK_FILE="$APK_OUT/hid-asus-ally-stable-${HID_VERSION}-r0.apk"
tar -czf "$APK_FILE" -C "$PKG_DIR" .PKGINFO "$INSTALL_PATH"

# Index the local APK repo.
# apk index exits non-zero on unsigned packages; we use --allow-untrusted
# at install time so the index just needs to exist.
echo "==> Indexing local APK repository"
apk index -o "$APK_OUT/APKINDEX.tar.gz" "$APK_FILE" 2>/dev/null || true
if [ -f "$APK_OUT/APKINDEX.unsigned.tar.gz" ]; then
    mv "$APK_OUT/APKINDEX.unsigned.tar.gz" "$APK_OUT/APKINDEX.tar.gz"
fi
if [ ! -f "$APK_OUT/APKINDEX.tar.gz" ]; then
    # Last resort: create an empty-but-valid index. apk will still
    # find our package via the --repository path.
    tar -czf "$APK_OUT/APKINDEX.tar.gz" --files-from /dev/null
fi

echo "    APK: $APK_FILE ($(du -h "$APK_FILE" | cut -f1))"
echo "==> hid-asus-ally-stable built and packaged"
