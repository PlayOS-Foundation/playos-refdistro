#!/usr/bin/env bash
# build-iso-ubuntu.sh — PlayOS image build orchestrator (distro dispatcher).
#
# Usage:
#   PLAYOS_DISTRO=alpine bash scripts/build-iso-ubuntu.sh    # default
#   PLAYOS_DISTRO=arch   bash scripts/build-iso-ubuntu.sh    # Arch + CachyOS
#
# Sets PLAYOS_KERNEL_VARIANT=cachyos|deckify for Arch handheld builds.
#
# Logging is automatically initialized — output goes to both console and
# logs/<run-id>/ directory.  Set PLAYOS_LOG_LEVEL=debug for verbose output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DISTRO="${PLAYOS_DISTRO:-alpine}"
KERNEL_VARIANT="${PLAYOS_KERNEL_VARIANT:-cachyos}"

# ── Source shared libraries ──────────────────────────────────────────────────
source "$ROOT/shared/logging.sh"
source "$ROOT/shared/verify-sibling-repos.sh"
source "$ROOT/shared/partition-layout.sh"
source "$ROOT/shared/bootloader-install.sh"

# ── Initialize logging + validate distro ─────────────────────────────────────
init_logging "build-iso-ubuntu"

case "$DISTRO" in
    alpine|arch) ;;
    *)
        log_error "unknown PLAYOS_DISTRO=$DISTRO (expect alpine or arch)"
        exit 1
        ;;
esac

log_info "PlayOS image build: distro=$DISTRO"
[ "$DISTRO" = "arch" ] && log_info "kernel variant: $KERNEL_VARIANT"

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
[ -n "${PLAYOS_SSH_PUBKEY:-}" ] && log_info "SSH key: $(echo "$PLAYOS_SSH_PUBKEY" | awk '{print $3}')"

# ── Set up EXIT trap early so close_logging always runs ──────────────────────
# (bash only supports one EXIT trap; the latest one wins)
_combined_trap() {
    local exit_code=$?
    cleanup_disk_layout 2>/dev/null || true
    close_logging "$exit_code" "Build of $DISTRO PlayOS image"
    # Fix log ownership — files written inside nspawn are root:root
    if [ -n "${PLAYOS_LOG_DIR:-}" ] && [ -d "$PLAYOS_LOG_DIR" ]; then
        sudo chown -R "$(id -u):$(id -g)" "$PLAYOS_LOG_DIR" 2>/dev/null || true
    fi
}
trap _combined_trap EXIT

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
log_step "Phase 0: Creating GPT disk image layout"
create_disk_layout "$IMAGE_NAME" "$IMAGE_SIZE_MB" "$ESP_SIZE_MB" "$ROOT_SIZE_MB" "$ROOT/out"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Build PlayOS components + populate disk image (nspawn)
# ══════════════════════════════════════════════════════════════════════════════
if [ "$DISTRO" = "alpine" ]; then
    # ── Alpine build ─────────────────────────────────────────────────────────
    ALPINE_BRANCH="${PLAYOS_ALPINE_BRANCH:-v3.24}"
    ROOTFS="$ROOT/.build/alpine-rootfs"
    MARKER="$ROOTFS/.playos-alpine-version"

    if [ ! -f "$MARKER" ]; then
        log_error "Alpine build root not initialized"
        log_info "Run: bash scripts/setup-ubuntu-build-host.sh"
        exit 1
    fi

    NSPAWN_EXTRA_BINDS=""
    [ -d "$REFDEV_SRC" ] && NSPAWN_EXTRA_BINDS="--bind=$REFDEV_SRC:/mnt/playos-reference-devices"

    # Translate host log path to /workspace-relative for nspawn
    NSPAWN_LOG_DIR="${PLAYOS_LOG_DIR/#$ROOT/\/workspace}"

    log_step "Phase 1: Building PlayOS components + Alpine disk image"
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
        --setenv="TERM=dumb" \
        --setenv="PLAYOS_ROOT=/workspace" \
        --setenv="PLAYOS_RUNTIME_SRC=/mnt/playos-runtime" \
        --setenv="PLAYOS_SHELL_SRC=/mnt/playos-shell" \
        --setenv="PLAYOS_PLATFORM_SRC=/mnt/playos-platform-api" \
        --setenv="PLAYOS_SAMPLES_SRC=/mnt/playos-samples" \
        --setenv="PLAYOS_ALPINE_BRANCH=${ALPINE_BRANCH}" \
        --setenv="PLAYOS_APORTS_BRANCH=${PLAYOS_APORTS_BRANCH:-3.24-stable}" \
        --setenv="PLAYOS_ARCH=${ARCH}" \
        --setenv="PLAYOS_SSH_PUBKEY=${PLAYOS_SSH_PUBKEY:-}" \
        --setenv="PLAYOS_WIFI_SSID=${PLAYOS_WIFI_SSID:-}" \
        --setenv="PLAYOS_WIFI_PSK=${PLAYOS_WIFI_PSK:-}" \
        --setenv="DISK_MNT=${DISK_MNT}" \
        --setenv="ROOT_UUID=${ROOT_UUID}" \
        --setenv="EFI_UUID=${EFI_UUID}" \
        --setenv="DATA_UUID=${DATA_UUID}" \
        --setenv="ROOT_PARTUUID=${ROOT_PARTUUID}" \
        --setenv="TMPDIR=/var/tmp" \
        --setenv="PLAYOS_LOG_DIR=${NSPAWN_LOG_DIR}" \
        --setenv="PLAYOS_LOG_LEVEL=${PLAYOS_LOG_LEVEL}" \
        /bin/sh -c '
            set -e
            /workspace/scripts/build-playos-components.sh
            /workspace/scripts/build-disk-image-alpine.sh
        '

    BOOTLOADER_ID="playos"
    KERNEL_IMAGE="/vmlinuz-stable"
    INITRD_IMAGE="/initramfs-stable"
    KERNEL_CMDLINE="root=UUID=${ROOT_UUID} rootfstype=ext4 rw console=tty0 console=ttyS0 amdgpu.sg_display=0 rootdelay=2 loglevel=7 cfg80211.ieee80211_regdom=GR softlevel=playos-visual"
    ISO_SCRIPT="build-alpine-iso.sh"

else
    # ── Arch build ───────────────────────────────────────────────────────────
    ROOTFS="$ROOT/.build/arch-rootfs"
    MARKER="$ROOTFS/.playos-arch-version"

    if [ ! -f "$MARKER" ]; then
        log_error "Arch build root not initialized"
        log_info "Run: bash scripts/setup-ubuntu-build-host.sh"
        exit 1
    fi

    NSPAWN_EXTRA_BINDS=""
    [ -d "$REFDEV_SRC" ] && NSPAWN_EXTRA_BINDS="--bind=$REFDEV_SRC:/mnt/playos-reference-devices"

    # Translate host log path to /workspace-relative for nspawn
    NSPAWN_LOG_DIR="${PLAYOS_LOG_DIR/#$ROOT/\/workspace}"

    log_step "Phase 1: Building PlayOS components + Arch disk image ($KERNEL_VARIANT)"
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
        --setenv="TERM=dumb" \
        --setenv="PLAYOS_ROOT=/workspace" \
        --setenv="PLAYOS_RUNTIME_SRC=/mnt/playos-runtime" \
        --setenv="PLAYOS_SHELL_SRC=/mnt/playos-shell" \
        --setenv="PLAYOS_PLATFORM_SRC=/mnt/playos-platform-api" \
        --setenv="PLAYOS_SAMPLES_SRC=/mnt/playos-samples" \
        --setenv="PLAYOS_KERNEL_VARIANT=${KERNEL_VARIANT}" \
        --setenv="PLAYOS_ARCH=${ARCH}" \
        --setenv="PLAYOS_SSH_PUBKEY=${PLAYOS_SSH_PUBKEY:-}" \
        --setenv="PLAYOS_WIFI_SSID=${PLAYOS_WIFI_SSID:-}" \
        --setenv="PLAYOS_WIFI_PSK=${PLAYOS_WIFI_PSK:-}" \
        --setenv="DISK_MNT=${DISK_MNT}" \
        --setenv="ROOT_UUID=${ROOT_UUID}" \
        --setenv="EFI_UUID=${EFI_UUID}" \
        --setenv="DATA_UUID=${DATA_UUID}" \
        --setenv="ROOT_PARTUUID=${ROOT_PARTUUID}" \
        --setenv="TMPDIR=/var/tmp" \
        --setenv="PLAYOS_LOG_DIR=${NSPAWN_LOG_DIR}" \
        --setenv="PLAYOS_LOG_LEVEL=${PLAYOS_LOG_LEVEL}" \
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
log_step "Phase 2: Installing bootloader (systemd-boot)"
install_bootloader "$DISK_MNT" "$BOOTLOADER_ID" "$KERNEL_IMAGE" "$INITRD_IMAGE" "$KERNEL_CMDLINE"
sync
log_success "Bootloader installed"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Compress + build ISO (inside nspawn)
# ══════════════════════════════════════════════════════════════════════════════
# Translate host log path to /workspace-relative for nspawn
NSPAWN_LOG_DIR="${PLAYOS_LOG_DIR/#$ROOT/\/workspace}"

log_step "Phase 3: Compressing disk image and building ISO"
sudo systemd-nspawn \
    --quiet \
    --directory="$ROOTFS" \
    --resolv-conf=replace-host \
    --bind="$ROOT:/workspace" \
    --setenv="TERM=dumb" \
    --setenv="PLAYOS_ROOT=/workspace" \
    --setenv="PLAYOS_ALPINE_BRANCH=${PLAYOS_ALPINE_BRANCH:-v3.24}" \
    --setenv="PLAYOS_APORTS_BRANCH=${PLAYOS_APORTS_BRANCH:-3.24-stable}" \
    --setenv="PLAYOS_KERNEL_VARIANT=${KERNEL_VARIANT}" \
    --setenv="PLAYOS_ARCH=${ARCH}" \
    --setenv="PLAYOS_SSH_PUBKEY=${PLAYOS_SSH_PUBKEY:-}" \
    --setenv="PLAYOS_WIFI_SSID=${PLAYOS_WIFI_SSID:-}" \
    --setenv="PLAYOS_WIFI_PSK=${PLAYOS_WIFI_PSK:-}" \
    --setenv="TMPDIR=/var/tmp" \
    --setenv="PLAYOS_LOG_DIR=${NSPAWN_LOG_DIR}" \
    --setenv="PLAYOS_LOG_LEVEL=${PLAYOS_LOG_LEVEL}" \
    /bin/sh -c '
        set -e

        echo "==> Compressing disk image"
        IMG=$(ls -1 /workspace/out/playos-gpt-*.img 2>/dev/null | head -1)
        if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
            echo "ERROR: No disk image found to compress" >&2
            exit 1
        fi
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
log_step "Phase 4: Finalizing artifacts"
ZST_PATH="${DISK_IMG}.zst"
if [ -f "$ZST_PATH" ]; then
    sudo chown "$(id -u):$(id -g)" "$ZST_PATH" "${ZST_PATH}.sha256" 2>/dev/null || true
    DISK_SIZE="$(du -h "$ZST_PATH" | cut -f1)"
    log_success "Disk image compressed: $(basename "$ZST_PATH") ($DISK_SIZE)"
    log_info "Checksum: ${ZST_PATH}.sha256"
fi

sudo chown -R "$(id -u):$(id -g)" "$ROOT/out"

log_info "Built images:"
while IFS= read -r f; do
    log_info "  $(ls -lh "$f" | awk '{print $5, $NF}')"
done < <(find "$ROOT/out" -maxdepth 1 -type f \( -name '*.iso' -o -name '*.img.zst' -o -name '*.sha256' \) 2>/dev/null || true)

# ── Deploy to PXE server ─────────────────────────────────────────────────────
PXE_DIR="/var/www/html/playos"
log_step "Deploying to PXE server: $PXE_DIR"

# Pick the NEWEST ISO — out/ may contain both alpine and arch ISOs, and a
# plain `find | head -1` can grab the wrong one (breaks PXE deploy).
ISO="$(find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' -printf '%T@ %p\n' \
    | sort -nr | head -n 1 | cut -d' ' -f2-)"
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
            log_warn "initramfs not found in ISO"
        if [ -f "$ROOT/arch/boot.ipxe" ]; then
            sudo cp "$ROOT/arch/boot.ipxe" "$PXE_DIR/"
        fi
    fi

    sudo chown -R www-data:www-data "$PXE_DIR"
    sudo umount "$MNT"
    rmdir "$MNT"

    log_info "Deployed: $(ls "$PXE_DIR"/*.iso 2>/dev/null | head -1)"
fi

log_step "Build complete — distro=$DISTRO variant=$KERNEL_VARIANT"
log_duration
