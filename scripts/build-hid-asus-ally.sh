#!/usr/bin/env bash
# build-hid-asus-ally.sh — Build the hid-asus-ally out-of-tree kernel module
# for the ROG Ally and package it as a local Alpine APK.
#
# Runs inside the Alpine nspawn container. Requires linux-stable-dev
# for kernel headers.
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"

# ── Initialize logging ──────────────────────────────────────────────────────
source "$ROOT/shared/logging-helpers.sh"

HID_VERSION="20240910"
HID_REPO="https://github.com/uejji/hid-asus-ally"
BUILD_DIR="${PLAYOS_BUILD_DIR:-/var/tmp/playos-build}"
APK_OUT="${PLAYOS_APK_OUT:-/var/tmp/playos-apks}"

_log_step "Building hid-asus-ally kernel module"

# Install kernel headers for the running kernel (linux-stable)
apk add --no-cache linux-stable-dev 2>&1 | tail -3 || true

# Get kernel version string (e.g., "7.1.5-0-stable").
# Pick the directory that has a "build" symlink (headers installed),
# falling back to the highest version if none have one.
KERNEL_VER=$(for d in /lib/modules/*/build; do dirname "$d"; done 2>/dev/null | head -1 | xargs basename)
if [ -z "$KERNEL_VER" ]; then
    KERNEL_VER=$(ls /lib/modules/ | sort -V | tail -1)
fi
_log_info "Kernel version: $KERNEL_VER"

# Clone the driver source
HID_SRC="$BUILD_DIR/hid-asus-ally"
if [ ! -d "$HID_SRC" ]; then
    git clone --depth 1 "$HID_REPO" "$HID_SRC"
    # Tag 20240910 points to a non-commit object — check out commit directly.
    cd "$HID_SRC"
    git checkout 71648145e013a10771051304fcd110bab83ce9b4
else
    _log_info "Using cached source at $HID_SRC"
fi

# Build the kernel module
_log_step "Compiling hid-asus-ally.ko"
make -C "$HID_SRC" \
    TARGET="$KERNEL_VER" \
    KERNEL_BUILD="/lib/modules/$KERNEL_VER/build" \
    -j"$(nproc)" modules

MODULE="$HID_SRC/hid-asus-ally.ko"
if [ ! -f "$MODULE" ]; then
    _log_error "module build failed — hid-asus-ally.ko not found"
    exit 1
fi

# ── Package as APK ──────────────────────────────────────────────────
_log_step "Packaging hid-asus-ally-stable APK"
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

# Create the .apk (APK v2: control.tar.gz + data.tar.gz concatenated, then signed).
# A valid APK v2 is: [signature tarball] + control tarball (with .PKGINFO) + data tarball (with files).
mkdir -p "$APK_OUT/x86_64"
APK_FILE="$APK_OUT/x86_64/hid-asus-ally-stable-${HID_VERSION}-r0.apk"

# Create the .apk (single gzip tarball — simple packaging, enough for disk-image install)
tar -czf "$APK_FILE" -C "$PKG_DIR" .PKGINFO "$INSTALL_PATH"

echo "==> Creating APKINDEX (non-fatal)"
# Index the APK so mkimage can install it into the ISO modloop.
# If the index is invalid, the disk image still has hid-asus-ally.ko directly.
apk index -o "$APK_OUT/x86_64/APKINDEX.tar.gz" "$APK_FILE" 2>/dev/null || true
echo "    APK: $APK_FILE ($(du -h "$APK_FILE" | cut -f1))"
echo "==> hid-asus-ally-stable built and packaged"
