#!/usr/bin/env bash
# build-disk-image.sh — Produce a raw GPT disk image for dd-based installation.
#
# This runs inside the Alpine nspawn container (or Docker equivalent) AFTER
# build-playos-components.sh has installed the compositor, shell, and
# installer binaries into /usr/bin.
#
# Output: out/playos-gpt-<version>-<arch>.img.zst + .sha256
#
# The image can be written directly to a target disk:
#   zstd -d < image.zst | dd of=/dev/nvme0n1 bs=4M
#   sgdisk -e /dev/nvme0n1
#   parted /dev/nvme0n1 resizepart 2 100%
#   resize2fs /dev/nvme0n1p2
#   reboot
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
OUT="$ROOT/out"
ALPINE_BRANCH="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"
IMAGE_SIZE_MB="${PLAYOS_IMAGE_SIZE_MB:-4096}"     # 4 GiB default, grows via resize at install time
ESP_SIZE_MB="${PLAYOS_ESP_SIZE_MB:-512}"           # 512 MiB EFI System Partition

IMAGE_NAME="playos-gpt-${ALPINE_BRANCH}-${ARCH}"

echo "==> Building PlayOS disk image: $IMAGE_NAME"
echo "    Image size: ${IMAGE_SIZE_MB} MiB"

mkdir -p "$OUT"

# ── Create sparse image ──────────────────────────────────────────────────────
echo "==> Creating ${IMAGE_SIZE_MB} MiB sparse image"
truncate -s "${IMAGE_SIZE_MB}M" "$OUT/$IMAGE_NAME.img"

# ── Partition with sgdisk ────────────────────────────────────────────────────
echo "==> Partitioning: GPT with ESP + root"
sgdisk -Z "$OUT/$IMAGE_NAME.img"                           # zap existing GPT/MBR
sgdisk -n "1:1M:+${ESP_SIZE_MB}M" -t 1:EF00 "$OUT/$IMAGE_NAME.img"   # EFI System Partition
sgdisk -n 2:0:0 -t 2:8300 "$OUT/$IMAGE_NAME.img"                        # Linux root, rest of image

# ── Mount via loop device ────────────────────────────────────────────────────
LOOP=$(losetup --find --show -P "$OUT/$IMAGE_NAME.img")
echo "    Loop device: $LOOP"

cleanup_loop() {
    echo "==> Cleaning up loop device"
    sync
    # Unmount in reverse order
    mountpoint -q /mnt/playos-image-root/boot/efi 2>/dev/null && umount /mnt/playos-image-root/boot/efi || true
    mountpoint -q /mnt/playos-image-root 2>/dev/null && umount /mnt/playos-image-root || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup_loop EXIT

# ── Format partitions ────────────────────────────────────────────────────────
echo "==> Formatting partitions"
mkfs.vfat -F32 -n PLAYOS_EFI "${LOOP}p1"
mkfs.ext4 -F -L playos-root "${LOOP}p2"

# ── Mount ────────────────────────────────────────────────────────────────────
mkdir -p /mnt/playos-image-root
mount "${LOOP}p2" /mnt/playos-image-root
mkdir -p /mnt/playos-image-root/boot/efi
mount "${LOOP}p1" /mnt/playos-image-root/boot/efi

# ── Install Alpine base system ───────────────────────────────────────────────
echo "==> Installing Alpine base system"
apk --root /mnt/playos-image-root --initdb add --no-cache alpine-base

# Required APK repositories inside the target root
mkdir -p /mnt/playos-image-root/etc/apk
cat > /mnt/playos-image-root/etc/apk/repositories <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
REPOS

# ── Install PlayOS packages ──────────────────────────────────────────────────
echo "==> Installing PlayOS system packages"
apk --root /mnt/playos-image-root add --no-cache \
    alpine-conf \
    bluez bluez-openrc \
    dbus dbus-openrc \
    eudev eudev-openrc \
    gptfdisk \
    glfw \
    iwd \
    libdrm \
    libinput \
    libxkbcommon \
    linux-firmware-amdgpu \
    linux-firmware-nvidia \
    linux-firmware-intel \
    linux-lts \
    mesa-dri-gallium \
    mesa-egl \
    mesa-gbm \
    mesa-gles \
    mesa-vulkan-ati \
    mesa-vulkan-nouveau \
    mesa-vulkan-intel \
    networkmanager networkmanager-openrc networkmanager-wifi \
    openssh \
    openrc \
    pipewire \
    raylib \
    seatd seatd-openrc \
    wayland \
    wireplumber wireplumber-openrc \
    wlroots0.19 \
    wpa_supplicant

# ── Copy PlayOS custom binaries ──────────────────────────────────────────────
echo "==> Copying PlayOS binaries"

# Compositor
if [ -f /usr/bin/playos-compositor ]; then
    install -m 0755 /usr/bin/playos-compositor /mnt/playos-image-root/usr/bin/playos-compositor
fi

# Shell
if [ -f /usr/bin/playos-shell ]; then
    install -m 0755 /usr/bin/playos-shell /mnt/playos-image-root/usr/bin/playos-shell
fi

# Installer GUI (needed for re-install from disk → disk)
if [ -f /usr/bin/playos-installer-gui ]; then
    install -m 0755 /usr/bin/playos-installer-gui /mnt/playos-image-root/usr/bin/playos-installer-gui
fi

# Shared libraries (shell links against these at runtime)
if [ -f /usr/lib/libraylib.so.450 ]; then
    cp -a /usr/lib/libraylib.so.450 /mnt/playos-image-root/usr/lib/
    ln -sf libraylib.so.450 /mnt/playos-image-root/usr/lib/libraylib.so
fi
if [ -f /usr/lib/libglfw.so.3 ]; then
    cp -a /usr/lib/libglfw.so.3 /mnt/playos-image-root/usr/lib/
fi

# ── Copy samples ─────────────────────────────────────────────────────────────
SAMPLES_DIR="/workspace/.build/samples-out"
if [ -d "$SAMPLES_DIR" ] && [ -f "$SAMPLES_DIR/hello-playos" ]; then
    echo "==> Bundling PlayOS samples"
    mkdir -p /mnt/playos-image-root/usr/share/playos
    install -m 0755 "$SAMPLES_DIR/hello-playos"   /mnt/playos-image-root/usr/share/playos/hello-playos
    install -m 0755 "$SAMPLES_DIR/space-invaders" /mnt/playos-image-root/usr/share/playos/space-invaders
fi

# ── Install compositor init script ───────────────────────────────────────────
if [ -f "$ROOT/alpine/init.d/playos-compositor" ]; then
    install -m 0755 "$ROOT/alpine/init.d/playos-compositor" \
        /mnt/playos-image-root/etc/init.d/playos-compositor
fi

# ── Create first-boot init script ────────────────────────────────────────────
echo "==> Installing first-boot service"
install -m 0755 "$ROOT/alpine/init.d/playos-firstboot" \
    /mnt/playos-image-root/etc/init.d/playos-firstboot

# ── Configure OpenRC runlevels ───────────────────────────────────────────────
echo "==> Configuring OpenRC runlevels"

# Helper: symlink init script into runlevel
rc_add() {
    mkdir -p "/mnt/playos-image-root/etc/runlevels/$2"
    ln -sf "/etc/init.d/$1" "/mnt/playos-image-root/etc/runlevels/$2/$1"
}

# Base boot services (sysinit)
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add udev sysinit
rc_add udev-trigger sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

# Base boot services (boot)
rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot

# Shutdown
rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

# PlayOS visual path (first-frame critical)
rc_add dbus default
rc_add seatd default
rc_add playos-compositor default

# Network (async — does not block compositor)
rc_add networkmanager default
rc_add wpa_supplicant default

# SSH debug access
rc_add sshd default

# First-boot one-shot (runs once, deletes itself)
rc_add playos-firstboot default

# ── Create firstboot flag file ───────────────────────────────────────────────
touch /mnt/playos-image-root/etc/playos/firstboot

# ── Hostname ─────────────────────────────────────────────────────────────────
echo "playos" > /mnt/playos-image-root/etc/hostname

# ── SSH debug key ────────────────────────────────────────────────────────────
mkdir -p /mnt/playos-image-root/root/.ssh
cat > /mnt/playos-image-root/root/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKjUiS/ZaOaGpyGkzotL9kUnsqOTpN07h0nZBpPwsDbP playos-debug
EOF
chmod 700 /mnt/playos-image-root/root/.ssh
chmod 600 /mnt/playos-image-root/root/.ssh/authorized_keys

# ── Kernel cmdline (applied by bootloader) ───────────────────────────────────
mkdir -p /mnt/playos-image-root/etc/kernel
cat > /mnt/playos-image-root/etc/kernel/cmdline <<'EOF'
console=tty0 amdgpu.sg_display=0 quiet loglevel=3
EOF

# ── fstab ────────────────────────────────────────────────────────────────────
ROOT_UUID=$(blkid -s UUID -o value "${LOOP}p2")
EFI_UUID=$(blkid -s UUID -o value "${LOOP}p1")

cat > /mnt/playos-image-root/etc/fstab <<EOF
# /etc/fstab — PlayOS installed system
UUID=$ROOT_UUID /         ext4  defaults,noatime  0 1
UUID=$EFI_UUID  /boot/efi vfat  defaults,noatime  0 2
EOF

# ── Install bootloader (systemd-boot) ────────────────────────────────────────
echo "==> Installing systemd-boot"
apk --root /mnt/playos-image-root add --no-cache systemd-boot 2>/dev/null || true

if command -v bootctl >/dev/null 2>&1; then
    bootctl install --root=/mnt/playos-image-root --esp-path=/boot/efi --no-variables 2>/dev/null || {
        echo "    bootctl install via host failed; trying chroot fallback"
    }

    KERNEL_VER=$(ls /mnt/playos-image-root/lib/modules/ | head -1)
    if [ -n "$KERNEL_VER" ]; then
        mkdir -p /mnt/playos-image-root/boot/efi/loader/entries

        # systemd-boot entry for PlayOS
        cat > /mnt/playos-image-root/boot/efi/loader/entries/playos.conf <<CONFENTRY
title   PlayOS
linux   /vmlinuz-lts
initrd  /initramfs-lts
options root=UUID=$ROOT_UUID rw console=tty0 amdgpu.sg_display=0 quiet loglevel=3
CONFENTRY

        # Default loader config
        cat > /mnt/playos-image-root/boot/efi/loader/loader.conf <<LOADERCONF
default playos.conf
timeout 0
console-mode keep
LOADERCONF

        # Copy kernel and initramfs to ESP
        cp "/mnt/playos-image-root/boot/vmlinuz-lts"     /mnt/playos-image-root/boot/efi/vmlinuz-lts
        cp "/mnt/playos-image-root/boot/initramfs-lts"   /mnt/playos-image-root/boot/efi/initramfs-lts
    fi
else
    echo "    systemd-boot not available in build environment — skipping bootloader"
    echo "    Boot entry will be created by playos-firstboot on first boot."
fi

# ── Unmount ──────────────────────────────────────────────────────────────────
echo "==> Unmounting image"
sync
umount /mnt/playos-image-root/boot/efi
umount /mnt/playos-image-root
losetup -d "$LOOP"
trap - EXIT  # disarm cleanup trap (already done manually)

# ── Compress ─────────────────────────────────────────────────────────────────
echo "==> Compressing with zstd"
UNCOMPRESSED_SIZE=$(du -h "$OUT/$IMAGE_NAME.img" | cut -f1)
zstd -T0 --rm -12 "$OUT/$IMAGE_NAME.img"
COMPRESSED_SIZE=$(du -h "$OUT/$IMAGE_NAME.img.zst" | cut -f1)
echo "    $UNCOMPRESSED_SIZE → $COMPRESSED_SIZE"

# ── Checksum ─────────────────────────────────────────────────────────────────
echo "==> Computing SHA-256 checksum"
sha256sum "$OUT/$IMAGE_NAME.img.zst" > "$OUT/$IMAGE_NAME.img.zst.sha256"
echo "    $(cat $OUT/$IMAGE_NAME.img.zst.sha256)"

echo "==> Disk image built: $OUT/$IMAGE_NAME.img.zst"
echo "==> Checksum:         $OUT/$IMAGE_NAME.img.zst.sha256"
