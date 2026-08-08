#!/usr/bin/env bash
# gen-ally-usb-image.sh — Create a USB-bootable disk image for ROG Ally
#
# Usage:
#   bash scripts/gen-ally-usb-image.sh <ally-output-dir>
#
# Produces: <ally-output-dir>/images/playos-ally-usb.img
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
HOST_DIR="$ALLY_OUTPUT/host"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR2_EXTERNAL="$SCRIPT_DIR/../br2-external"

# ── Find boot artifacts ────────────────────────────────────────────
BZIMAGE=""
INITRAMFS=""

for candidate in "$IMAGES_DIR/bzImage" "$ALLY_OUTPUT/build/linux-"*/arch/x86/boot/bzImage; do
    if [[ -f "$candidate" ]]; then
        BZIMAGE="$candidate"
        break
    fi
done

for candidate in "$IMAGES_DIR/rootfs.cpio" "$IMAGES_DIR/rootfs.initramfs"; do
    if [[ -f "$candidate" ]]; then
        INITRAMFS="$candidate"
        break
    fi
done

if [[ -z "$BZIMAGE" ]]; then
    echo "ERROR: Kernel image not found. Run 'make ally-build' first." >&2
    exit 1
fi

if [[ -z "$INITRAMFS" ]]; then
    echo "ERROR: initramfs not found. Run 'make ally-build' first." >&2
    exit 1
fi

echo "==> Kernel:     $BZIMAGE"
echo "==> initramfs:  $INITRAMFS"

# ── Calculate image size ───────────────────────────────────────────
ESP_SIZE_MB=256
SYSTEM_A_SIZE_MB=2048
DATA_SIZE_MB=1024
IMAGE_SIZE_MB=$((ESP_SIZE_MB + SYSTEM_A_SIZE_MB + DATA_SIZE_MB + 1))  # +1 for GPT overhead
IMAGE_SIZE_SECTORS=$((IMAGE_SIZE_MB * 2048))

IMAGE_PATH="$IMAGES_DIR/playos-ally-usb.img"
echo "==> Creating disk image: ${IMAGE_SIZE_MB} MiB..."

# Create empty sparse image
dd if=/dev/zero of="$IMAGE_PATH" bs=1M count="$IMAGE_SIZE_MB" status=none 2>/dev/null

# ── Partition with sgdisk (GPT) ─────────────────────────────────────
# Check for sgdisk
if command -v sgdisk &>/dev/null; then
    sgdisk --zap-all "$IMAGE_PATH"
    sgdisk -n 1:2048:+${ESP_SIZE_MB}M      -t 1:EF00 -c 1:"ESP"        "$IMAGE_PATH"
    sgdisk -n 2:0:+${SYSTEM_A_SIZE_MB}M     -t 2:8300 -c 2:"playos-a"   "$IMAGE_PATH"
    sgdisk -n 3:0:+${DATA_SIZE_MB}M         -t 3:8300 -c 3:"playos-data" "$IMAGE_PATH"
else
    echo "WARNING: sgdisk not found. Falling back to sfdisk."
    # sfdisk fallback
    ESP_START=2048
    ESP_END=$((ESP_START + ESP_SIZE_MB * 2048 - 1))
    SYSTEM_START=$((ESP_END + 1))
    SYSTEM_END=$((SYSTEM_START + SYSTEM_A_SIZE_MB * 2048 - 1))
    DATA_START=$((SYSTEM_END + 1))
    DATA_END=$((DATA_START + DATA_SIZE_MB * 2048 - 1))

    sfdisk "$IMAGE_PATH" <<EOF
label: gpt
start=$ESP_START, size=$((ESP_SIZE_MB * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
start=$SYSTEM_START, size=$((SYSTEM_A_SIZE_MB * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="playos-a"
start=$DATA_START, size=$((DATA_SIZE_MB * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="playos-data"
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
sleep 1  # Wait for partition detection

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

# ── Mount and populate ESP ─────────────────────────────────────────
ESP_MOUNT="$(mktemp -d)"
sudo mount "$ESP_PART" "$ESP_MOUNT"

# Create ESP directory structure
sudo mkdir -p "$ESP_MOUNT/EFI/BOOT"
sudo mkdir -p "$ESP_MOUNT/boot"

# Copy kernel and initramfs
sudo cp "$BZIMAGE" "$ESP_MOUNT/boot/bzImage"
sudo cp "$INITRAMFS" "$ESP_MOUNT/boot/initramfs.cpio"
echo "==> Kernel and initramfs copied to ESP."

# Copy GRUB config
sudo cp "$BR2_EXTERNAL/board/ally/grub.cfg" "$ESP_MOUNT/boot/grub/grub.cfg" 2>/dev/null || \
    sudo mkdir -p "$ESP_MOUNT/boot/grub" && \
    sudo cp "$BR2_EXTERNAL/board/ally/grub.cfg" "$ESP_MOUNT/boot/grub/grub.cfg"

# Install GRUB EFI bootloader
if command -v grub-install &>/dev/null; then
    sudo grub-install \
        --target=x86_64-efi \
        --efi-directory="$ESP_MOUNT" \
        --boot-directory="$ESP_MOUNT/boot" \
        --removable \
        --recheck \
        "$LOOP_DEV" 2>/dev/null || \
        echo "WARNING: grub-install failed. The image may need manual GRUB setup."
else
    echo "WARNING: grub-install not found. GRUB EFI bootloader not installed."
    echo "         For UEFI boot, copy BOOTX64.EFI to EFI/BOOT/ manually."
fi

# Use host GRUB from Buildroot if available
if [[ -d "$HOST_DIR" ]]; then
    HOST_GRUB="$HOST_DIR/sbin/grub-install"
    if [[ -x "$HOST_GRUB" ]]; then
        echo "==> Using Buildroot host grub-install..."
        sudo "$HOST_GRUB" \
            --target=x86_64-efi \
            --efi-directory="$ESP_MOUNT" \
            --boot-directory="$ESP_MOUNT/boot" \
            --removable \
            "$LOOP_DEV" 2>/dev/null || true
    fi
fi

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
echo "  To flash to USB:  make ally-flash"
echo "  Or manually:      sudo dd if=$IMAGE_PATH of=/dev/sdX bs=4M status=progress conv=fsync"
echo ""
