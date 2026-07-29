#!/usr/bin/env bash
# bootloader-install.sh — Install systemd-boot to the ESP.
#
# Must run on the HOST (not inside nspawn) because --bind doesn't
# propagate sub-mounts — the ESP is unmountable from inside nspawn.
#
# Usage:
#   install_bootloader DISK_MNT BOOTLOADER_ID KERNEL_IMAGE INITRD_IMAGE CMDLINE
#
# BOOTLOADER_ID is used for:
#   - loader/entries/<BOOTLOADER_ID>.conf
#   - Default entry name in loader.conf

set -euo pipefail

install_bootloader() {
    local DISK_MNT="${1:?}"
    local BOOTLOADER_ID="${2:?}"
    local KERNEL_IMAGE="${3:?}"    # relative to ESP root, e.g. /vmlinuz-stable
    local INITRD_IMAGE="${4:?}"   # relative to ESP root, e.g. /initramfs-stable
    local CMDLINE="${5:?}"

    local STUB="${DISK_MNT}/usr/lib/systemd/boot/efi/systemd-bootx64.efi"

    if [ ! -f "$STUB" ]; then
        log_warn "systemd-boot stub not found at $STUB — skipping bootloader install"
        return 0
    fi

    log_step "Installing systemd-boot to ESP"

    sudo mkdir -p "${DISK_MNT}/boot/efi/EFI/BOOT"
    sudo mkdir -p "${DISK_MNT}/boot/efi/EFI/systemd"
    sudo mkdir -p "${DISK_MNT}/boot/efi/loader/entries"

    sudo cp "$STUB" "${DISK_MNT}/boot/efi/EFI/BOOT/BOOTX64.EFI"
    sudo cp "$STUB" "${DISK_MNT}/boot/efi/EFI/systemd/systemd-bootx64.efi"

    local KERNEL_VER
    KERNEL_VER="$(ls "${DISK_MNT}/lib/modules/" | head -1)"
    if [ -z "$KERNEL_VER" ]; then
        log_warn "no kernel modules found — skipping bootloader configuration"
        return 0
    fi

    sudo tee "${DISK_MNT}/boot/efi/loader/entries/${BOOTLOADER_ID}.conf" > /dev/null <<CONFENTRY
title   PlayOS
linux   ${KERNEL_IMAGE}
initrd  ${INITRD_IMAGE}
options ${CMDLINE}
CONFENTRY

    sudo tee "${DISK_MNT}/boot/efi/loader/loader.conf" > /dev/null <<LOADERCONF
default ${BOOTLOADER_ID}.conf
timeout 0
console-mode keep
LOADERCONF

    # Copy kernel and initramfs to ESP (strip leading / for source paths)
    local KERNEL_SRC="${KERNEL_IMAGE#/}"
    local INITRD_SRC="${INITRD_IMAGE#/}"
    if [ -f "${DISK_MNT}/boot/${KERNEL_SRC}" ]; then
        sudo cp "${DISK_MNT}/boot/${KERNEL_SRC}"   "${DISK_MNT}/boot/efi/${KERNEL_SRC}"
    elif [ -f "${DISK_MNT}/boot/vmlinuz-stable" ]; then
        sudo cp "${DISK_MNT}/boot/vmlinuz-stable"   "${DISK_MNT}/boot/efi/vmlinuz-stable"
    else
        log_warn "kernel image not found — skipping kernel copy to ESP"
    fi
    if [ -f "${DISK_MNT}/boot/${INITRD_SRC}" ]; then
        sudo cp "${DISK_MNT}/boot/${INITRD_SRC}" "${DISK_MNT}/boot/efi/${INITRD_SRC}"
    elif [ -f "${DISK_MNT}/boot/initramfs-stable" ]; then
        sudo cp "${DISK_MNT}/boot/initramfs-stable" "${DISK_MNT}/boot/efi/initramfs-stable"
    else
        log_warn "initramfs image not found — skipping initramfs copy to ESP"
    fi
    log_success "systemd-boot installed to ESP (entry: ${BOOTLOADER_ID}.conf)"
}
