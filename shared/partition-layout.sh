#!/usr/bin/env bash
# partition-layout.sh — Create + partition + format + mount a GPT disk image.
#
# Sources this script or call the function:
#   create_disk_layout IMAGE_NAME IMAGE_SIZE_MB ESP_SIZE_MB ROOT_SIZE_MB
#
# Sets these variables in the caller's scope:
#   DISK_IMG LOOP_DEV DISK_MNT ROOT_UUID EFI_UUID DATA_UUID ROOT_PARTUUID
#
# Exports a cleanup function: cleanup_disk_layout

set -euo pipefail

create_disk_layout() {
    local IMAGE_NAME="${1:?}"
    local IMAGE_SIZE_MB="${2:?}"
    local ESP_SIZE_MB="${3:?}"
    local ROOT_SIZE_MB="${4:?}"
    local OUT_DIR="${5:-.}"

    DISK_IMG="$OUT_DIR/${IMAGE_NAME}.img"

    echo "==> Creating ${IMAGE_SIZE_MB} MiB disk image layout (ESP + root + data)"
    rm -f "$DISK_IMG"
    truncate -s "${IMAGE_SIZE_MB}M" "$DISK_IMG"
    sgdisk -Z "$DISK_IMG"
    sgdisk -n "1:1M:+${ESP_SIZE_MB}M" -t 1:EF00 "$DISK_IMG"
    sgdisk -n "2:0:+${ROOT_SIZE_MB}M" -t 2:8300 "$DISK_IMG"
    sgdisk -n 3:0:0 -t 3:8300 "$DISK_IMG"

    LOOP_DEV="$(sudo losetup --find --show -P "$DISK_IMG")"
    echo "    Loop: $LOOP_DEV"

    sudo mkfs.vfat -F32 -n PLAYOS_EFI "${LOOP_DEV}p1"
    sudo mkfs.ext4 -F -L playos-root "${LOOP_DEV}p2"
    sudo mkfs.ext4 -F -L playos-data "${LOOP_DEV}p3"

    DISK_MNT="/mnt/playos-image-root"
    sudo mkdir -p "$DISK_MNT"
    sudo mount "${LOOP_DEV}p2" "$DISK_MNT"
    sudo mkdir -p "$DISK_MNT/boot/efi" "$DISK_MNT/data"
    sudo mount "${LOOP_DEV}p1" "$DISK_MNT/boot/efi"
    sudo mount "${LOOP_DEV}p3" "$DISK_MNT/data"
    echo "    Mounted at $DISK_MNT"

    # Grab filesystem UUIDs while mounted
    ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP_DEV}p2")"
    EFI_UUID="$(sudo blkid -s UUID -o value "${LOOP_DEV}p1")"
    DATA_UUID="$(sudo blkid -s UUID -o value "${LOOP_DEV}p3")"
    ROOT_PARTUUID="$(sudo blkid -s PARTUUID -o value "${LOOP_DEV}p2")"
    echo "    Root UUID: $ROOT_UUID"
    echo "    EFI  UUID: $EFI_UUID"
    echo "    Data UUID: $DATA_UUID"
    echo "    Root PARTUUID: $ROOT_PARTUUID"
}

# Call this in a trap: trap cleanup_disk_layout EXIT
cleanup_disk_layout() {
    echo "==> Cleaning up disk image mounts"
    sudo mountpoint -q "$DISK_MNT/data" 2>/dev/null && sudo umount "$DISK_MNT/data" || true
    sudo mountpoint -q "$DISK_MNT/boot/efi" 2>/dev/null && sudo umount "$DISK_MNT/boot/efi" || true
    sudo mountpoint -q "$DISK_MNT" 2>/dev/null && sudo umount "$DISK_MNT" || true
    sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    sudo rmdir "$DISK_MNT/boot/efi" "$DISK_MNT/data" "$DISK_MNT" 2>/dev/null || true
}
