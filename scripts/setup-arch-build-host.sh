#!/usr/bin/env bash
# setup-arch-build-host.sh — one-time setup for building PlayOS ISO
# on a native Arch Linux system (VM, bare metal, or WSL).
# Installs archiso and required build tools.
set -euo pipefail

echo "==> Installing archiso and build dependencies"
sudo pacman -S --needed --noconfirm \
  archiso \
  grub \
  base-devel \
  git \
  cmake \
  ninja \
  gcc \
  pkgconf \
  wlroots0.19 \
  wayland-protocols

echo "==> Done. Run scripts/build-iso-vmware.sh to build the ISO."
