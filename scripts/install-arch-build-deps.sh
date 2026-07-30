#!/usr/bin/env bash
# install-arch-build-deps.sh — Bootstrap an Arch Linux build root for nspawn.
#
# Downloads and verifies the official Arch Linux bootstrap tarball,
# extracts it, and installs build dependencies via pacman.
#
# Runs inside systemd-nspawn after bootstrap extraction (or on host for
# initial setup).
set -euo pipefail

ARCH_BOOTSTRAP_DATE="${PLAYOS_ARCH_BOOTSTRAP_DATE:-2026.07.01}"
ARCH="${PLAYOS_ARCH:-x86_64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOTFS="$ROOT/.build/arch-rootfs"
MARKER="$ROOTFS/.playos-arch-version"

echo "==> Installing Arch build dependencies"

# Build tools only — runtime packages are installed by build-disk-image-arch.sh
# during disk population. This script installs what build-playos-components.sh needs.
pacman -Sy --noconfirm --disable-download-timeout \
    base-devel \
    cmake \
    ninja \
    git \
    meson \
    pkgconf \
    mkinitcpio \
    mtools \
    wayland-protocols \
    libxkbcommon \
    libinput \
    seatd \
    mesa \
    libdrm \
    glfw \
    libx11 \
    libxrandr \
    libxi \
    libxcursor \
    libxinerama \
    curl \
    xorriso \
    wlroots0.19

echo "    Arch build deps installed"
