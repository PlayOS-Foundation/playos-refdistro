#!/usr/bin/env bash
# fstab-generate.sh — Generate /etc/fstab for a PlayOS disk image.
#
# Usage:
#   generate_fstab ROOTFS_DIR ROOT_UUID EFI_UUID DATA_UUID
#
# Or source and call the function directly.

set -euo pipefail

generate_fstab() {
    local MNT="${1:?}"
    local ROOT_UUID="${2:?}"
    local EFI_UUID="${3:?}"
    local DATA_UUID="${4:?}"

    echo "==> Generating fstab"

    cat > "$MNT/etc/fstab" <<EOF
# /etc/fstab — PlayOS installed system
UUID=$ROOT_UUID /         ext4  defaults,noatime  0 1
UUID=$EFI_UUID  /boot/efi vfat  defaults,noatime  0 2
UUID=$DATA_UUID /data     ext4  defaults,noatime  0 2
EOF
}
