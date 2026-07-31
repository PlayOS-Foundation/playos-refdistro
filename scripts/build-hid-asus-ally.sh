#!/usr/bin/env bash
# build-hid-asus-ally.sh — Build the hid-asus-ally out-of-tree kernel module
# for the ROG Ally.
#
# Callers copy the resulting .ko from /var/tmp/playos-build/hid-asus-ally/
# into their target module tree for initramfs/modloop inclusion.
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

# ── Report ───────────────────────────────────────────────────────────
echo "==> hid-asus-ally.ko built at $MODULE ($(du -h "$MODULE" | cut -f1))"
echo "    Kernel: $KERNEL_VER"
