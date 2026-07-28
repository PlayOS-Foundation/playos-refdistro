#!/usr/bin/env bash
# build-iso-ubuntu.sh — PlayOS image build orchestrator (distro dispatcher).
#
# Usage:
#   PLAYOS_DISTRO=alpine bash scripts/build-iso-ubuntu.sh    # default
#   PLAYOS_DISTRO=arch   bash scripts/build-iso-ubuntu.sh    # Arch + CachyOS
#
# Sets PLAYOS_KERNEL_VARIANT=cachyos|deckify for Arch handheld builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DISTRO="${PLAYOS_DISTRO:-alpine}"
KERNEL_VARIANT="${PLAYOS_KERNEL_VARIANT:-cachyos}"

# ── Validate distro selection ────────────────────────────────────────────────
case "$DISTRO" in
    alpine|arch) ;;
    *)
        echo "error: unknown PLAYOS_DISTRO=$DISTRO (expect alpine or arch)" >&2
        exit 1
        ;;
esac

echo "==> PlayOS image build: distro=$DISTRO"
[ "$DISTRO" = "arch" ] && echo "    kernel variant: $KERNEL_VARIANT"

# ── Source shared libraries ──────────────────────────────────────────────────
source "$ROOT/shared/verify-sibling-repos.sh"
source "$ROOT/shared/partition-layout.sh"
source "$ROOT/shared/bootloader-install.sh"

# ── Sibling repo paths ───────────────────────────────────────────────────────
RUNTIME_SRC="${PLAYOS_RUNTIME_SRC:-$ROOT/../playos-runtime}"
SHELL_SRC="${PLAYOS_SHELL_SRC:-$ROOT/../playos-shell}"
PLATFORM_SRC="${PLAYOS_PLATFORM_SRC:-$ROOT/../playos-platform-api}"
SAMPLES_SRC="${PLAYOS_SAMPLES_SRC:-$ROOT/../playos-samples}"
REFDEV_SRC="${PLAYOS_REFERENCE_DEVICES:-$ROOT/../playos-reference-devices}"

# ── SSH key (nspawn can't see host ~/.ssh) ──────────────────────────────────
if [ -n "${PLAYOS_SSH_PUBKEY:-}" ]; then
    :
elif [ -f "${HOME}/.ssh/id_ed25519.pub" ]; then
    PLAYOS_SSH_PUBKEY="$(cat "${HOME}/.ssh/id_ed25519.pub")"
elif [ -f "${HOME}/.ssh/id_rsa.pub" ]; then
    PLAYOS_SSH_PUBKEY="$(cat "${HOME}/.ssh/id_rsa.pub")"
fi
[ -n "${PLAYOS_SSH_PUBKEY:-}" ] && echo "==> SSH key: $(echo "$PLAYOS_SSH_PUBKEY" | awk '{print $3}')"

# ── Verify repos ─────────────────────────────────────────────────────────────
verify_sibling_repos "$RUNTIME_SRC" "$SHELL_SRC" "$PLATFORM_SRC" "$SAMPLES_SRC" "$REFDEV_SRC"

# ── Image params ─────────────────────────────────────────────────────────────
if [ "$DISTRO" = "alpine" ]; then
    VERSION_TAG="${PLAYOS_ALPINE_BRANCH:-v3.24}"
else
    VERSION_TAG="${PLAYOS_KERNEL_VARIANT:-cachyos}"
fi
ARCH="${PLAYOS_ARCH:-x86_64}"
IMAGE_NAME="playos-gpt-${DISTRO}-${VERSION_TAG}-${ARCH}"
IMAGE_SIZE_MB="${PLAYOS_IMAGE_SIZE_MB:-6144}"
ESP_SIZE_MB="${PLAYOS_ESP_SIZE_MB:-512}"
ROOT_SIZE_MB="${PLAYOS_ROOT_SIZE_MB:-4096}"

mkdir -p "$ROOT/out"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 0: Create GPT disk image (host-side, shared)
# ══════════════════════════════════════════════════════════════════════════════
create_disk_layout "$IMAGE_NAME" "$IMAGE_SIZE_MB" "$ESP_SIZE_MB" "$ROOT_SIZE_MB" "$ROOT/out"

# shellcheck disable=SC2064
trap "cleanup_disk_layout" EXIT

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Build PlayOS components + populate disk image (nspawn)
# ══════════════════════════════════════════════════════════════════════════════
if [ "$DISTRO" = "alpine" ]; then
    # ── Alpine build ─────────────────────────────────────────────────────────
    ALPINE_BRANCH="${PLAYOS_ALPINE_BRANCH:-v3.24}"
    ROOTFS="$ROOT/.build/alpine-rootfs"
    MARKER="$ROOTFS/.playos-alpine-version"

    if [ ! -f "$MARKER" ]; then
        echo "error: Alpine build root not initialized" >&2
        echo "Run: bash scripts/setup-ubuntu-build-host.sh" >&2
        exit 1
    fi

    NSPAWN_EXTRA_BINDS=""
    [ -d "$REFDEV_SRC" ] && NSPAWN_EXTRA_BINDS="--bind=$REFDEV_SRC:/mnt/playos-reference-devices"

    echo "==> Phase 1: Building PlayOS components + Alpine disk image"
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
        $NSPAWN_EXTRA_BINDS \
        --setenv="PLAYOS_ROOT=/workspace" \
        --setenv="PLAYOS_RUNTIME_SRC=/mnt/playos-runtime" \
        --setenv="PLAYOS_SHELL_SRC=/mnt/playos-shell" \
        --setenv="PLAYOS_PLATFORM_SRC=/mnt/playos-platform-api" \
        --setenv="PLAYOS_SAMPLES_SRC=/mnt/playos-samples" \
        --setenv="PLAYOS_ALPINE_BRANCH=${ALPINE_BRANCH}" \
        --setenv="PLAYOS_APORTS_BRANCH=${PLAYOS_APORTS_BRANCH:-3.24-stable}" \
        --setenv="PLAYOS_ARCH=${ARCH}" \
        --setenv="PLAYOS_SSH_PUBKEY=${PLAYOS_SSH_PUBKEY:-}" \
        --setenv="DISK_MNT=${DISK_MNT}" \
        --setenv="ROOT_UUID=${ROOT_UUID}" \
        --setenv="EFI_UUID=${EFI_UUID}" \
        --setenv="DATA_UUID=${DATA_UUID}" \
        --setenv="ROOT_PARTUUID=${ROOT_PARTUUID}" \
        --setenv="TMPDIR=/var/tmp" \
        /bin/sh -c '
            set -e
            /workspace/scripts/build-playos-components.sh
            /workspace/scripts/build-disk-image-alpine.sh
        '

    BOOTLOADER_ID="playos"
    KERNEL_IMAGE="/vmlinuz-stable"
    INITRD_IMAGE="/initramfs-stable"
    KERNEL_CMDLINE="root=UUID=${ROOT_UUID} rootfstype=ext4 rw console=tty0 console=ttyS0 amdgpu.sg_display=0 rootdelay=2 loglevel=7 softlevel=playos-visual"
    ISO_SCRIPT="build-alpine-iso.sh"

else
    # ── Arch build ───────────────────────────────────────────────────────────
    ROOTFS="$ROOT/.build/arch-rootfs"
    MARKER="$ROOTFS/.playos-arch-version"

    if [ ! -f "$MARKER" ]; then
        echo "error: Arch build root not initialized" >&2
        echo "Run: bash scripts/setup-ubuntu-build-host.sh" >&2
        exit 1
    fi

    NSPAWN_EXTRA_BINDS=""
    [ -d "$REFDEV_SRC" ] && NSPAWN_EXTRA_BINDS="--bind=$REFDEV_SRC:/mnt/playos-reference-devices"

    echo "==> Phase 1: Building PlayOS components + Arch disk image ($KERNEL_VARIANT)"
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
        $NSPAWN_EXTRA_BINDS \
        --setenv="PLAYOS_ROOT=/workspace" \
        --setenv="PLAYOS_RUNTIME_SRC=/mnt/playos-runtime" \
        --setenv="PLAYOS_SHELL_SRC=/mnt/playos-shell" \
        --setenv="PLAYOS_PLATFORM_SRC=/mnt/playos-platform-api" \
        --setenv="PLAYOS_SAMPLES_SRC=/mnt/playos-samples" \
        --setenv="PLAYOS_KERNEL_VARIANT=${KERNEL_VARIANT}" \
        --setenv="PLAYOS_ARCH=${ARCH}" \
        --setenv="PLAYOS_SSH_PUBKEY=${PLAYOS_SSH_PUBKEY:-}" \
        --setenv="DISK_MNT=${DISK_MNT}" \
        --setenv="ROOT_UUID=${ROOT_UUID}" \
        --setenv="EFI_UUID=${EFI_UUID}" \
        --setenv="DATA_UUID=${DATA_UUID}" \
        --setenv="ROOT_PARTUUID=${ROOT_PARTUUID}" \
        --setenv="TMPDIR=/var/tmp" \
        /bin/sh -c '
            set -e
            /workspace/scripts/build-playos-components.sh
            /workspace/scripts/build-disk-image-arch.sh
        '

    BOOTLOADER_ID="playos"
    KERNEL_IMAGE="/vmlinuz-stable"
    INITRD_IMAGE="/initramfs-stable"
    KERNEL_CMDLINE="root=UUID=${ROOT_UUID} rootfstype=ext4 rw console=tty0 console=ttyS0 amdgpu.sg_display=0 rootdelay=2 loglevel=7"
    ISO_SCRIPT="build-arch-iso.sh"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: Install bootloader (host-side — nspawn can't see sub-mounts)
# ══════════════════════════════════════════════════════════════════════════════
install_bootloader "$DISK_MNT" "$BOOTLOADER_ID" "$KERNEL_IMAGE" "$INITRD_IMAGE" "$KERNEL_CMDLINE"
sync

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Compress + build ISO (inside nspawn)
# ══════════════════════════════════════════════════════════════════════════════
echo "==> Compressing disk image and building ISO"
sudo systemd-nspawn \
    --quiet \
    --directory="$ROOTFS" \
    --resolv-conf=replace-host \
    --bind="$ROOT:/workspace" \
    --setenv="PLAYOS_ROOT=/workspace" \
    --setenv="PLAYOS_ALPINE_BRANCH=${PLAYOS_ALPINE_BRANCH:-v3.24}" \
    --setenv="PLAYOS_APORTS_BRANCH=${PLAYOS_APORTS_BRANCH:-3.24-stable}" \
    --setenv="PLAYOS_KERNEL_VARIANT=${KERNEL_VARIANT}" \
    --setenv="PLAYOS_ARCH=${ARCH}" \
    --setenv="PLAYOS_SSH_PUBKEY=${PLAYOS_SSH_PUBKEY:-}" \
    --setenv="TMPDIR=/var/tmp" \
    /bin/sh -c '
        set -e

        echo "==> Compressing disk image"
        IMG=$(echo /workspace/out/playos-gpt-*.img | head -1)
        zstd -f -T0 --rm -12 "$IMG"
        IMG_ZST="${IMG}.zst"
        (
            cd "$(dirname "$IMG_ZST")"
            sha256sum "$(basename "$IMG_ZST")" > "$(basename "$IMG_ZST").sha256"
        )

        /workspace/scripts/'"$ISO_SCRIPT"'
    '

# ══════════════════════════════════════════════════════════════════════════════
# Phase 4: Fix ownership + deploy PXE (shared)
# ══════════════════════════════════════════════════════════════════════════════
ZST_PATH="${DISK_IMG}.zst"
if [ -f "$ZST_PATH" ]; then
    sudo chown "$(id -u):$(id -g)" "$ZST_PATH" "${ZST_PATH}.sha256" 2>/dev/null || true
    DISK_SIZE="$(du -h "$ZST_PATH" | cut -f1)"
    echo "==> Disk image compressed: $ZST_PATH ($DISK_SIZE)"
    echo "    Checksum: ${ZST_PATH}.sha256"
fi

sudo chown -R "$(id -u):$(id -g)" "$ROOT/out"

echo
echo "Built images:"
find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' -exec ls -lh {} \;
find "$ROOT/out" -maxdepth 1 -type f \( -name '*.img.zst' -o -name '*.sha256' \) -exec ls -lh {} \; 2>/dev/null || true

# ── Deploy to PXE server ─────────────────────────────────────────────────────
PXE_DIR="/var/www/html/playos"
echo
echo "==> Deploying to PXE server: $PXE_DIR"

ISO="$(find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' | head -1)"
if [ -n "$ISO" ] && [ -f "$ISO" ]; then
    MNT="$(mktemp -d)"
    sudo mount -o loop,ro "$ISO" "$MNT"

    sudo cp "$ISO" "$PXE_DIR/${DISTRO}-playos-${VERSION_TAG}-${ARCH}.iso"

    if [ "$DISTRO" = "alpine" ]; then
        sudo cp "$MNT/playos.apkovl.tar.gz" "$PXE_DIR/"
        sudo cp "$MNT/boot/vmlinuz-stable" "$PXE_DIR/"
        sudo cp "$MNT/boot/initramfs-stable" "$PXE_DIR/"
        PXE_INITRAMFS="$(mktemp)"
        "$ROOT/scripts/build-pxe-initramfs.sh" "$MNT/boot/initramfs-stable" "$PXE_INITRAMFS"
        sudo cp "$PXE_INITRAMFS" "$PXE_DIR/initramfs-pxe-stable"
        rm -f "$PXE_INITRAMFS"
        sudo cp "$MNT/boot/modloop-stable" "$PXE_DIR/"
        sudo rm -rf "$PXE_DIR/apks"
        sudo cp -r "$MNT/apks" "$PXE_DIR/"
        sudo cp "$ROOT/alpine/boot.ipxe" "$PXE_DIR/"
    else
        # Arch PXE — copy kernel and initramfs from ISO
        sudo cp "$MNT/boot/vmlinuz-linux" "$PXE_DIR/vmlinuz-stable" 2>/dev/null || \
            sudo cp "$MNT/boot/vmlinuz-linux-cachyos" "$PXE_DIR/vmlinuz-stable" 2>/dev/null || \
            echo "    WARNING: kernel not found in ISO"
        sudo cp "$MNT/boot/initramfs-linux.img" "$PXE_DIR/initramfs-stable" 2>/dev/null || \
            echo "    WARNING: initramfs not found in ISO"
        if [ -f "$ROOT/arch/boot.ipxe" ]; then
            sudo cp "$ROOT/arch/boot.ipxe" "$PXE_DIR/"
        fi
    fi

    sudo chown -R www-data:www-data "$PXE_DIR"
    sudo umount "$MNT"
    rmdir "$MNT"

    echo "  Deployed: $(ls "$PXE_DIR"/*.iso 2>/dev/null | head -1)"
fi

echo
echo "==> Build complete: distro=$DISTRO variant=$KERNEL_VARIANT"
