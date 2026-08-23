#!/usr/bin/env bash
# gen-installer-usb-image.sh — Create the one-shot PlayOS installer USB image
#
# Usage:
#   bash scripts/gen-installer-usb-image.sh <installer-output-dir> <ally-output-dir> [image-name]
#
# Produces: <installer-output-dir>/images/<image-name>
#           (image-name defaults to playos-ally-installer.img)
#
# The installer USB carries TWO kernels:
#   * ESP/EFI/BOOT/BOOTX64.EFI  — installer kernel (CONFIG_CMDLINE has
#     playos.mode=install), booted by UEFI when the medium is selected.
#   * playos-a/BOOTX64.EFI      — normal production kernel, written verbatim
#     to the target ESP during installation.
#   * playos-a/rootfs.squashfs  — system image, written verbatim to the
#     target playos-a slot during installation.
#
# Partition layout (GPT):
#   1. ESP        256 MiB  FAT32  (installer EFI stub)
#   2. playos-a   2048 MiB ext2   (install payload: squashfs + normal kernel)
#   3. playos-data ~1 GiB  ext4   (scratch / preserved diagnostics)

set -euo pipefail

INSTALLER_OUTPUT="${1:-}"
ALLY_OUTPUT="${2:-}"
IMAGE_NAME="${3:-playos-ally-installer.img}"
if [[ -z "$INSTALLER_OUTPUT" || -z "$ALLY_OUTPUT" ]]; then
    echo "ERROR: Missing output directory argument(s)." >&2
    echo "Usage: $0 <installer-output-dir> <ally-output-dir> [image-name]" >&2
    exit 1
fi

INSTALLER_IMAGES_DIR="$INSTALLER_OUTPUT/images"
ALLY_IMAGES_DIR="$ALLY_OUTPUT/images"

# ── Find boot artifacts ────────────────────────────────────────────
INSTALLER_BZIMAGE=""
for candidate in "$INSTALLER_IMAGES_DIR/bzImage" "$INSTALLER_OUTPUT/build/linux-"*/arch/x86/boot/bzImage; do
    if [[ -f "$candidate" ]]; then
        INSTALLER_BZIMAGE="$candidate"
        break
    fi
done

ALLY_BZIMAGE=""
for candidate in "$ALLY_IMAGES_DIR/bzImage" "$ALLY_OUTPUT/build/linux-"*/arch/x86/boot/bzImage; do
    if [[ -f "$candidate" ]]; then
        ALLY_BZIMAGE="$candidate"
        break
    fi
done

SQUASHFS="$ALLY_IMAGES_DIR/rootfs.squashfs"

if [[ -z "$INSTALLER_BZIMAGE" ]]; then
    echo "ERROR: Installer kernel not found. Run 'make installer-build' first." >&2
    exit 1
fi
if [[ -z "$ALLY_BZIMAGE" ]]; then
    echo "ERROR: Production kernel not found. Run 'make ally-build' first." >&2
    exit 1
fi
if [[ ! -f "$SQUASHFS" ]]; then
    echo "ERROR: rootfs.squashfs not found. Enable BR2_TARGET_ROOTFS_SQUASHFS and rebuild." >&2
    exit 1
fi

# Verify both are EFI stub kernels
for KERNEL in "$INSTALLER_BZIMAGE" "$ALLY_BZIMAGE"; do
    if ! grep -aq "EFI.*STUB" "$KERNEL" 2>/dev/null && ! file "$KERNEL" 2>/dev/null | grep -q "EFI"; then
        echo "WARNING: Kernel may not be built with CONFIG_EFI_STUB=y: $KERNEL" >&2
    fi
done

echo "==> Installer kernel (EFI stub): $INSTALLER_BZIMAGE"
echo "==> Production kernel (payload): $ALLY_BZIMAGE"
echo "==> System image (payload):      $SQUASHFS"

# ── Calculate image size ───────────────────────────────────────────
ESP_SIZE_MB=256
SYSTEM_A_SIZE_MB=2048
IMAGE_SIZE_MB=$((ESP_SIZE_MB + SYSTEM_A_SIZE_MB + 1024 + 2))
IMAGE_PATH="$INSTALLER_IMAGES_DIR/$IMAGE_NAME"
echo "==> Creating disk image: ${IMAGE_SIZE_MB} MiB..."

truncate -s "${IMAGE_SIZE_MB}M" "$IMAGE_PATH"

# ── Partition with sgdisk (GPT) ─────────────────────────────────────
if command -v sgdisk &>/dev/null; then
    sgdisk --zap-all "$IMAGE_PATH"
    sgdisk -n 1:2048:+${ESP_SIZE_MB}M      -t 1:EF00 -c 1:"ESP"        "$IMAGE_PATH"
    sgdisk -n 2:0:+${SYSTEM_A_SIZE_MB}M     -t 2:8300 -c 2:"playos-a"   "$IMAGE_PATH"
    sgdisk -n 3:0:0                         -t 3:8300 -c 3:"playos-data" "$IMAGE_PATH"
else
    echo "WARNING: sgdisk not found. Falling back to sfdisk."
    ESP_START=2048
    sfdisk "$IMAGE_PATH" <<EOF
label: gpt
start=$ESP_START, size=$((ESP_SIZE_MB * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
start=$((ESP_START + ESP_SIZE_MB * 2048)), size=$((SYSTEM_A_SIZE_MB * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="playos-a"
start=$((ESP_START + (ESP_SIZE_MB + SYSTEM_A_SIZE_MB) * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="playos-data"
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

sudo mkfs.fat -F32 -n "ESP" "$ESP_PART" 2>/dev/null
echo "==> ESP formatted (FAT32)"

sudo mkfs.ext2 -q -F -L "playos-a" "$SYSTEM_PART" 2>/dev/null
echo "==> playos-a formatted (ext2)"

sudo mkfs.ext4 -q -F -L "playos-data" "$DATA_PART" 2>/dev/null
echo "==> playos-data formatted (ext4)"

# ── Mount and populate ESP with the installer kernel ───────────────
ESP_MOUNT="$(mktemp -d)"
sudo mount "$ESP_PART" "$ESP_MOUNT"
sudo mkdir -p "$ESP_MOUNT/EFI/BOOT"
sudo cp "$INSTALLER_BZIMAGE" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
echo "==> Installer kernel installed as EFI/BOOT/BOOTX64.EFI"
sudo umount "$ESP_MOUNT"
rmdir "$ESP_MOUNT"

# ── Mount playos-a and stage the install payload ───────────────────
PAYLOAD_MOUNT="$(mktemp -d)"
sudo mount "$SYSTEM_PART" "$PAYLOAD_MOUNT"
sudo cp "$SQUASHFS" "$PAYLOAD_MOUNT/rootfs.squashfs"
sudo cp "$ALLY_BZIMAGE" "$PAYLOAD_MOUNT/BOOTX64.EFI"
echo "==> Payload staged on playos-a (rootfs.squashfs + BOOTX64.EFI)"
sudo umount "$PAYLOAD_MOUNT"
rmdir "$PAYLOAD_MOUNT"

# ── Seed developer SSH key into playos-data ────────────────────────
# The installer (step 5) copies /data/ssh/authorized_keys from this USB's
# data partition into the target NVMe's data partition, so key auth works
# on first boot. Optional: with no key present the stock image still
# installs and boots, it simply accepts no SSH client key.
DEV_PUBKEY=""
for _k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -s "$_k" ]]; then DEV_PUBKEY="$_k"; break; fi
done

DATA_MOUNT="$(mktemp -d)"
sudo mount "$DATA_PART" "$DATA_MOUNT"
if [[ -n "$DEV_PUBKEY" ]]; then
    sudo mkdir -p "$DATA_MOUNT/ssh"
    sudo cp "$DEV_PUBKEY" "$DATA_MOUNT/ssh/authorized_keys"
    echo "==> Seeded developer SSH key: $DEV_PUBKEY -> data/ssh/authorized_keys"
else
    echo "==> No ~/.ssh/id_ed25519.pub (or id_rsa.pub) found — SSH key not seeded"
fi
sudo umount "$DATA_MOUNT"
rmdir "$DATA_MOUNT"

# ── Cleanup loop device ────────────────────────────────────────────
sudo losetup -d "$LOOP_DEV"
LOOP_DEV=""

echo ""
echo "  ╔════════════════════════════════════════════════════════╗"
echo "  ║      PlayOS installer USB image created successfully!   ║"
echo "  ╚════════════════════════════════════════════════════════╝"
echo ""
echo "  Image: $IMAGE_PATH"
echo "  Size:  $(du -h "$IMAGE_PATH" | cut -f1)"
echo ""
echo "  Boot: EFI stub — UEFI boots the installer kernel directly."
echo "        playos-init spawns the installer via playos.mode=install."
echo ""
echo "  To flash to USB:  make installer-flash"
echo "  Or manually:      sudo dd if=$IMAGE_PATH of=/dev/sdX bs=4M status=progress conv=fsync"
echo ""
