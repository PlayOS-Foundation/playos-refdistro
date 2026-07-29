#!/usr/bin/env bash
# build-arch-iso.sh — Build PlayOS Arch ISO using archiso.
#
# Runs inside systemd-nspawn (Arch build root).
# Expects the disk image already compressed at out/playos-gpt-*.img.zst.
#
# Output: out/playos-arch-<variant>-x86_64.iso
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"

# ── Initialize logging ──────────────────────────────────────────────────────
source "$ROOT/shared/logging-helpers.sh"

KERNEL_VARIANT="${PLAYOS_KERNEL_VARIANT:-cachyos}"
ARCH="${PLAYOS_ARCH:-x86_64}"

_log_step "Building PlayOS Arch ISO (kernel: $KERNEL_VARIANT)"

ISO_NAME="playos-arch-${KERNEL_VARIANT}-${ARCH}"
OUT_DIR="$ROOT/out"
ARCH_PROFILE="$ROOT/arch"

# ── Build a minimal archiso profile on the fly ───────────────────────────────
ISO_ROOT="$(mktemp -d)"
trap 'rm -rf "$ISO_ROOT"' EXIT

_log_step "Assembling ISO root at $ISO_ROOT"

# EFI bootloader
mkdir -p "$ISO_ROOT/EFI/BOOT"
cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || \
    _log_warn "systemd-boot stub not found — ISO may not boot"

# Kernel + initramfs (copy from build container)
mkdir -p "$ISO_ROOT/boot"
if [ -f /boot/vmlinuz-linux-cachyos-deckify ]; then
    cp /boot/vmlinuz-linux-cachyos-deckify "$ISO_ROOT/boot/vmlinuz-linux"
elif [ -f /boot/vmlinuz-linux-cachyos ]; then
    cp /boot/vmlinuz-linux-cachyos "$ISO_ROOT/boot/vmlinuz-linux"
elif [ -f /boot/vmlinuz-linux ]; then
    cp /boot/vmlinuz-linux "$ISO_ROOT/boot/vmlinuz-linux"
fi

if [ -f /boot/initramfs-linux.img ]; then
    cp /boot/initramfs-linux.img "$ISO_ROOT/boot/initramfs-linux.img"
elif [ -f /boot/initramfs-linux-cachyos.img ]; then
    cp /boot/initramfs-linux-cachyos.img "$ISO_ROOT/boot/initramfs-linux.img"
fi

# Loader config
mkdir -p "$ISO_ROOT/loader/entries"
cat > "$ISO_ROOT/loader/entries/playos-arch.conf" <<EOF
title   PlayOS Arch (${KERNEL_VARIANT})
linux   /boot/vmlinuz-linux
initrd  /boot/initramfs-linux.img
options archisobasedir=playos archiso_http_srv=http://\${pxe-server}/playos console=tty0 console=ttyS0,115200 amdgpu.sg_display=0 loglevel=7
EOF

cat > "$ISO_ROOT/loader/loader.conf" <<EOF
default playos-arch.conf
timeout 0
console-mode keep
EOF

# Bundle compressed disk image in ISO
mkdir -p "$ISO_ROOT/playos"
# Use a targeted glob (arch-specific) to avoid picking up Alpine images
# and use ls -1 so head -1 gets exactly one filename even with multiple matches.
IMG_ZST="$(ls -1 "$OUT_DIR"/playos-gpt-arch-*.img.zst 2>/dev/null | head -1)"
if [ -n "$IMG_ZST" ] && [ -f "$IMG_ZST" ]; then
    cp "$IMG_ZST" "$ISO_ROOT/playos/"
    if [ -f "${IMG_ZST}.sha256" ]; then
        cp "${IMG_ZST}.sha256" "$ISO_ROOT/playos/"
    fi
    _log_info "Disk image bundled: $(basename "$IMG_ZST")"
else
    _log_warn "No Arch disk image found in $OUT_DIR — ISO will not contain a disk image"
fi

# ── Build ISO with xorriso ───────────────────────────────────────────────────
_log_step "Writing ISO: $OUT_DIR/$ISO_NAME.iso"
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "PLAYOS_ARCH" \
    -appid "PlayOS Arch ${KERNEL_VARIANT}" \
    -eltorito-boot EFI/BOOT/BOOTX64.EFI \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/BOOT/BOOTX64.EFI \
    -no-emul-boot \
    -output "$OUT_DIR/$ISO_NAME.iso" \
    "$ISO_ROOT"

_log_info "ISO: $OUT_DIR/$ISO_NAME.iso ($(du -h "$OUT_DIR/$ISO_NAME.iso" | cut -f1))"
