#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOTFS="$ROOT/.build/alpine-rootfs"
MARKER="$ROOTFS/.playos-alpine-version"

if [[ ! -f "$MARKER" ]]; then
    echo "error: Alpine build root is not initialized" >&2
    echo "Run: bash scripts/setup-ubuntu-build-host.sh" >&2
    exit 1
fi

mkdir -p "$ROOT/out"

# PlayOS source repos (sibling directories).
RUNTIME_SRC="${PLAYOS_RUNTIME_SRC:-$ROOT/../playos-runtime}"
SHELL_SRC="${PLAYOS_SHELL_SRC:-$ROOT/../playos-shell}"
PLATFORM_SRC="${PLAYOS_PLATFORM_SRC:-$ROOT/../playos-platform-api}"
SAMPLES_SRC="${PLAYOS_SAMPLES_SRC:-$ROOT/../playos-samples}"

echo "==> Building PlayOS compositor + shell + disk image + ISO"

# ── Phase 0: Create disk image layout on the host ────────────────────────────
# sgdisk + losetup -P needs the host kernel for partition device nodes.
ALPINE_BRANCH="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"
IMAGE_NAME="playos-gpt-${ALPINE_BRANCH}-${ARCH}"
IMAGE_SIZE_MB="${PLAYOS_IMAGE_SIZE_MB:-4096}"
ESP_SIZE_MB="${PLAYOS_ESP_SIZE_MB:-512}"

DISK_IMG="$ROOT/out/$IMAGE_NAME.img"

echo "==> Creating ${IMAGE_SIZE_MB} MiB disk image layout"
rm -f "$DISK_IMG"
truncate -s "${IMAGE_SIZE_MB}M" "$DISK_IMG"
sgdisk -Z "$DISK_IMG"
sgdisk -n "1:1M:+${ESP_SIZE_MB}M" -t 1:EF00 "$DISK_IMG"
sgdisk -n 2:0:0 -t 2:8300 "$DISK_IMG"

LOOP_DEV=$(sudo losetup --find --show -P "$DISK_IMG")
echo "    Loop: $LOOP_DEV"

sudo mkfs.vfat -F32 -n PLAYOS_EFI "${LOOP_DEV}p1"
sudo mkfs.ext4 -F -L playos-root "${LOOP_DEV}p2"

DISK_MNT="/mnt/playos-image-root"
sudo mkdir -p "$DISK_MNT"
sudo mount "${LOOP_DEV}p2" "$DISK_MNT"
sudo mkdir -p "$DISK_MNT/boot/efi"
sudo mount "${LOOP_DEV}p1" "$DISK_MNT/boot/efi"
echo "    Mounted at $DISK_MNT"

# Grab filesystem UUIDs while mounted (for fstab inside nspawn)
ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p2")
EFI_UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p1")
echo "    Root UUID: $ROOT_UUID"
echo "    EFI  UUID: $EFI_UUID"

# Cleanup on exit
cleanup_disk() {
    echo "==> Cleaning up disk image mounts"
    sudo mountpoint -q "$DISK_MNT/boot/efi" 2>/dev/null && sudo umount "$DISK_MNT/boot/efi" || true
    sudo mountpoint -q "$DISK_MNT" 2>/dev/null && sudo umount "$DISK_MNT" || true
    sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    sudo rmdir "$DISK_MNT/boot/efi" "$DISK_MNT" 2>/dev/null || true
}
trap cleanup_disk EXIT

# ── Phase 1: Build components + populate disk image + build ISO ──────────────
sudo systemd-nspawn \
    --quiet \
    --directory="$ROOTFS" \
    --resolv-conf=replace-host \
    --bind="$ROOT:/workspace" \
    --bind="$RUNTIME_SRC:/mnt/playos-runtime" \
    --bind="$SHELL_SRC:/mnt/playos-shell" \
    --bind="$PLATFORM_SRC:/mnt/playos-platform-api" \
    --bind="$SAMPLES_SRC:/mnt/playos-samples" \
    --bind="$DISK_MNT:$DISK_MNT" \
    --setenv="PLAYOS_ROOT=/workspace" \
    --setenv="PLAYOS_RUNTIME_SRC=/mnt/playos-runtime" \
    --setenv="PLAYOS_SHELL_SRC=/mnt/playos-shell" \
    --setenv="PLAYOS_PLATFORM_SRC=/mnt/playos-platform-api" \
    --setenv="PLAYOS_SAMPLES_SRC=/mnt/playos-samples" \
    --setenv="PLAYOS_ALPINE_BRANCH=${ALPINE_BRANCH}" \
    --setenv="PLAYOS_APORTS_BRANCH=${PLAYOS_APORTS_BRANCH:-3.24-stable}" \
    --setenv="PLAYOS_ARCH=${ARCH}" \
    --setenv="DISK_MNT=${DISK_MNT}" \
    --setenv="ROOT_UUID=${ROOT_UUID}" \
    --setenv="EFI_UUID=${EFI_UUID}" \
    --setenv="TMPDIR=/var/tmp" \
    /bin/sh -c '
        set -e
        /workspace/scripts/build-playos-components.sh
        /workspace/scripts/build-disk-image.sh

        # Compress disk image now so genapkovl can bundle it into the ISO
        echo "==> Compressing disk image for ISO bundling"
        IMG=$(echo /workspace/out/playos-gpt-*.img | head -1)
        zstd -T0 --rm -12 "$IMG"
        sha256sum "${IMG}.zst" > "${IMG}.zst.sha256"

        /workspace/scripts/build-alpine-iso.sh
    '

# ── Phase 2: The disk image was already compressed inside nspawn ────────────
ZST_PATH="${DISK_IMG}.zst"
if [ -f "$ZST_PATH" ]; then
    sudo chown "$(id -u):$(id -g)" "$ZST_PATH" "${ZST_PATH}.sha256" 2>/dev/null || true
    DISK_SIZE=$(du -h "$ZST_PATH" | cut -f1)
    echo "==> Disk image compressed: $ZST_PATH ($DISK_SIZE)"
    echo "    Checksum: ${ZST_PATH}.sha256"
fi

sudo chown -R "$(id -u):$(id -g)" "$ROOT/out"

echo
echo "Built images:"
find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' -exec ls -lh {} \;
find "$ROOT/out" -maxdepth 1 -type f \( -name '*.img.zst' -o -name '*.sha256' \) -exec ls -lh {} \; 2>/dev/null || true

# === Deploy to PXE server ===
PXE_DIR="/var/www/html/playos"
echo
echo "==> Deploying to PXE server: $PXE_DIR"

ISO=$(find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' | head -1)
if [ -n "$ISO" ] && [ -f "$ISO" ]; then
    MNT=$(mktemp -d)
    sudo mount -o loop,ro "$ISO" "$MNT"
    
    sudo cp "$ISO" "$PXE_DIR/alpine-playos-${PLAYOS_ALPINE_BRANCH:-v3.24}-${PLAYOS_ARCH:-x86_64}.iso"
    sudo cp "$MNT/playos.apkovl.tar.gz" "$PXE_DIR/"
    sudo cp "$MNT/boot/vmlinuz-lts" "$PXE_DIR/"
    sudo cp "$MNT/boot/initramfs-lts" "$PXE_DIR/"
    sudo cp "$MNT/boot/modloop-lts" "$PXE_DIR/"
    sudo rm -rf "$PXE_DIR/apks"
    sudo cp -r "$MNT/apks" "$PXE_DIR/"
    sudo chown -R www-data:www-data "$PXE_DIR"
    
    sudo umount "$MNT"
    rmdir "$MNT"
    
    echo "  Deployed: $(ls "$PXE_DIR"/*.iso 2>/dev/null | head -1)"
    echo "  APK cache: $(ls "$PXE_DIR/apks/x86_64"/*.apk 2>/dev/null | wc -l) packages"

    # Deploy disk image if built
    DISK_IMG=$(find "$ROOT/out" -maxdepth 1 -type f -name '*.img.zst' 2>/dev/null | head -1)
    if [ -n "$DISK_IMG" ] && [ -f "$DISK_IMG" ]; then
        sudo cp "$DISK_IMG" "$PXE_DIR/"
        sudo cp "${DISK_IMG}.sha256" "$PXE_DIR/" 2>/dev/null || true
        sudo chown www-data:www-data "$PXE_DIR/$(basename "$DISK_IMG")" 2>/dev/null || true
        echo "  Disk image: $(basename "$DISK_IMG")"
    fi
else
    echo "  ERROR: No ISO found to deploy"
fi
