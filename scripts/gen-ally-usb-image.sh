#!/usr/bin/env bash
# gen-ally-usb-image.sh — Create a USB-bootable disk image for ROG Ally
#
# Usage:
#   bash scripts/gen-ally-usb-image.sh <ally-output-dir>
#
# Produces: <ally-output-dir>/images/playos-ally-usb.img
#
# Boot method: EFI stub (CONFIG_EFI_STUB=y).
# The kernel bzImage with embedded initramfs is placed as
# EFI/BOOT/BOOTX64.EFI — no intermediate bootloader.
#
# Partition layout (GPT):
#   1. ESP        256 MiB  FAT32  (EFI System Partition)
#   2. playos-a   2048 MiB ext2   (System A, immutable)
#   3. playos-data ~1 GiB  ext4   (Data, writable)

set -euo pipefail

ALLY_OUTPUT="${1:-}"
if [[ -z "$ALLY_OUTPUT" ]]; then
    echo "ERROR: Missing ally output directory argument." >&2
    echo "Usage: $0 <ally-output-dir>" >&2
    exit 1
fi

IMAGES_DIR="$ALLY_OUTPUT/images"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Find boot artifacts ────────────────────────────────────────────
BZIMAGE=""

for candidate in "$IMAGES_DIR/bzImage" "$ALLY_OUTPUT/build/linux-"*/arch/x86/boot/bzImage; do
    if [[ -f "$candidate" ]]; then
        BZIMAGE="$candidate"
        break
    fi
done

if [[ -z "$BZIMAGE" ]]; then
    echo "ERROR: Kernel image not found. Run 'make ally-build' first." >&2
    exit 1
fi

# Verify this is an EFI stub kernel
if ! grep -aq "EFI.*STUB" "$BZIMAGE" 2>/dev/null && ! file "$BZIMAGE" 2>/dev/null | grep -q "EFI"; then
    echo "WARNING: Kernel may not be built with CONFIG_EFI_STUB=y." >&2
    echo "         UEFI direct boot may fail." >&2
fi

echo "==> Kernel (EFI stub): $BZIMAGE"

# ── Calculate image size ───────────────────────────────────────────
ESP_SIZE_MB=256
SYSTEM_A_SIZE_MB=2048
DATA_SIZE_MB=1024
IMAGE_SIZE_MB=$((ESP_SIZE_MB + SYSTEM_A_SIZE_MB + DATA_SIZE_MB + 1))
IMAGE_PATH="$IMAGES_DIR/playos-ally-usb.img"
echo "==> Creating disk image: ${IMAGE_SIZE_MB} MiB..."

# Create empty sparse image
dd if=/dev/zero of="$IMAGE_PATH" bs=1M count="$IMAGE_SIZE_MB" status=none 2>/dev/null

# ── Partition with sgdisk (GPT) ─────────────────────────────────────
if command -v sgdisk &>/dev/null; then
    sgdisk --zap-all "$IMAGE_PATH"
    sgdisk -n 1:2048:+${ESP_SIZE_MB}M      -t 1:EF00 -c 1:"ESP"        "$IMAGE_PATH"
    sgdisk -n 2:0:+${SYSTEM_A_SIZE_MB}M     -t 2:8300 -c 2:"playos-a"   "$IMAGE_PATH"
    sgdisk -n 3:0:+${DATA_SIZE_MB}M         -t 3:8300 -c 3:"playos-data" "$IMAGE_PATH"
else
    echo "WARNING: sgdisk not found. Falling back to sfdisk."
    ESP_START=2048
    sfdisk "$IMAGE_PATH" <<EOF
label: gpt
start=$ESP_START, size=$((ESP_SIZE_MB * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
start=$((ESP_START + ESP_SIZE_MB * 2048)), size=$((SYSTEM_A_SIZE_MB * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="playos-a"
start=$((ESP_START + (ESP_SIZE_MB + SYSTEM_A_SIZE_MB) * 2048)), size=$((DATA_SIZE_MB * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="playos-data"
EOF
fi

echo "==> Partitions created."

# ── Format partitions using loop device ────────────────────────────
LOOP_DEV=""
cleanup_loop() {
    if [[ -n "$LOOP_DEV" ]]; then
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
}
trap cleanup_loop EXIT

LOOP_DEV=$(sudo losetup --partscan --find --show "$IMAGE_PATH")
echo "==> Loop device: $LOOP_DEV"
sleep 1

ESP_PART="${LOOP_DEV}p1"
SYSTEM_PART="${LOOP_DEV}p2"
DATA_PART="${LOOP_DEV}p3"

# Format ESP as FAT32
sudo mkfs.fat -F32 -n "ESP" "$ESP_PART" 2>/dev/null
echo "==> ESP formatted (FAT32)"

# Format system A as ext2
sudo mkfs.ext2 -q -F -L "playos-a" "$SYSTEM_PART" 2>/dev/null
echo "==> System A formatted (ext2)"

# Format data as ext4
sudo mkfs.ext4 -q -F -L "playos-data" "$DATA_PART" 2>/dev/null
echo "==> Data formatted (ext4)"

# ── Mount and populate ESP (EFI stub boot — no GRUB) ──────────────
ESP_MOUNT="$(mktemp -d)"
sudo mount "$ESP_PART" "$ESP_MOUNT"

# Create ESP directory structure
sudo mkdir -p "$ESP_MOUNT/EFI/BOOT"

# Place kernel as EFI/BOOT/BOOTX64.EFI (EFI stub — UEFI boots it directly)
sudo cp "$BZIMAGE" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
echo "==> Kernel installed as EFI/BOOT/BOOTX64.EFI (EFI stub, no GRUB)"

sudo umount "$ESP_MOUNT"
rmdir "$ESP_MOUNT"

# ── Cleanup loop device ────────────────────────────────────────────
sudo losetup -d "$LOOP_DEV"
LOOP_DEV=""

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║     ROG Ally USB image created successfully!     ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
echo "  Image: $IMAGE_PATH"
echo "  Size:  $(du -h "$IMAGE_PATH" | cut -f1)"
echo ""
echo "  Boot:  EFI stub — UEFI boots EFI/BOOT/BOOTX64.EFI directly"
echo ""
echo "  To flash to USB:  make ally-flash"
echo "  Or manually:      sudo dd if=$IMAGE_PATH of=/dev/sdX bs=4M status=progress conv=fsync"
echo ""
