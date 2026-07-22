#!/usr/bin/env bash
# build-disk-image.sh — Populate a pre-mounted disk image with PlayOS.
#
# Two modes:
#   DISK_MNT set in env → image is already partitioned + mounted at $DISK_MNT
#   DISK_MNT empty      → create+partition+format+mount a new image
#
# Output: out/playos-gpt-<version>-<arch>.img.zst + .sha256
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
OUT="$ROOT/out"
ALPINE_BRANCH="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"
IMAGE_SIZE_MB="${PLAYOS_IMAGE_SIZE_MB:-4096}"
ESP_SIZE_MB="${PLAYOS_ESP_SIZE_MB:-512}"
IMAGE_NAME="playos-gpt-${ALPINE_BRANCH}-${ARCH}"
MNT="${DISK_MNT:-}"

echo "==> Building PlayOS disk image: $IMAGE_NAME"
mkdir -p "$OUT"

# ── Phase 1: Create + partition + format + mount (only when no DISK_MNT) ──────
MUST_CLEANUP=""
if [ -z "$MNT" ]; then
    echo "==> Creating ${IMAGE_SIZE_MB} MiB sparse image"
    truncate -s "${IMAGE_SIZE_MB}M" "$OUT/$IMAGE_NAME.img"

    echo "==> Partitioning: GPT with ESP + root"
    sgdisk -Z "$OUT/$IMAGE_NAME.img"
    sgdisk -n "1:1M:+${ESP_SIZE_MB}M" -t 1:EF00 "$OUT/$IMAGE_NAME.img"
    sgdisk -n 2:0:0 -t 2:8300 "$OUT/$IMAGE_NAME.img"

    LOOP=$(losetup --find --show -P "$OUT/$IMAGE_NAME.img")
    echo "    Loop device: $LOOP"

    echo "==> Formatting partitions"
    mkfs.vfat -F32 -n PLAYOS_EFI "${LOOP}p1"
    mkfs.ext4 -F -L playos-root "${LOOP}p2"

    MNT="/mnt/playos-image-root"
    mkdir -p "$MNT"
    mount "${LOOP}p2" "$MNT"
    mkdir -p "$MNT/boot/efi"
    mount "${LOOP}p1" "$MNT/boot/efi"

    MUST_CLEANUP="yes"

    cleanup_loop() {
        echo "==> Unmounting + detaching loop device"
        sync
        mountpoint -q "$MNT/boot/efi" 2>/dev/null && umount "$MNT/boot/efi" || true
        mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" || true
        losetup -d "$LOOP" 2>/dev/null || true
    }
    trap cleanup_loop EXIT
else
    echo "==> Using pre-mounted disk image at $MNT"
fi

# ── Install Alpine base system ───────────────────────────────────────────────
echo "==> Installing Alpine base system"

# APK repos MUST exist before any --root install, since apk reads them from the target root
mkdir -p $MNT/etc/apk
cat > $MNT/etc/apk/repositories <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
REPOS

mkdir -p $MNT/etc/apk/keys
cp /etc/apk/keys/* $MNT/etc/apk/keys/

apk --root $MNT --initdb add --no-cache alpine-base

# ── Install PlayOS packages ──────────────────────────────────────────────────
echo "==> Installing PlayOS system packages"
apk --root $MNT add --no-cache \
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
    linux-firmware-mediatek \
    linux-lts \
    mesa-dri-gallium \
    mesa-egl \
    mesa-gbm \
    mesa-gles \
    mesa-vulkan-ati \
    mesa-vulkan-nouveau \
    mesa-vulkan-intel \
    networkmanager networkmanager-openrc networkmanager-wifi networkmanager-cli networkmanager-tui \
    openssh \
    openrc \
    pipewire \
    raylib \
    seatd seatd-openrc \
    wayland \
    wireplumber wireplumber-openrc \
    wlroots0.19 \
    systemd-boot \
    efibootmgr \
    wpa_supplicant

# ── Copy PlayOS custom binaries ──────────────────────────────────────────────
echo "==> Copying PlayOS binaries"

# Compositor
if [ -f /usr/bin/playos-compositor ]; then
    install -m 0755 /usr/bin/playos-compositor $MNT/usr/bin/playos-compositor
fi

# Shell
if [ -f /usr/bin/playos-shell ]; then
    install -m 0755 /usr/bin/playos-shell $MNT/usr/bin/playos-shell
fi

# Installer GUI (needed for re-install from disk → disk)
if [ -f /usr/bin/playos-installer-gui ]; then
    install -m 0755 /usr/bin/playos-installer-gui $MNT/usr/bin/playos-installer-gui
fi

# Shared libraries (shell links against these at runtime)
if [ -f /usr/lib/libraylib.so.450 ]; then
    cp -a /usr/lib/libraylib.so.450 $MNT/usr/lib/
    ln -sf libraylib.so.450 $MNT/usr/lib/libraylib.so
fi
if [ -f /usr/lib/libglfw.so.3 ]; then
    cp -a /usr/lib/libglfw.so.3 $MNT/usr/lib/
fi

# ── Copy samples ─────────────────────────────────────────────────────────────
SAMPLES_DIR="/workspace/.build/samples-out"
if [ -d "$SAMPLES_DIR" ] && [ -f "$SAMPLES_DIR/hello-playos" ]; then
    echo "==> Bundling PlayOS samples"
    mkdir -p $MNT/playos-samples/build
    install -m 0755 "$SAMPLES_DIR/hello-playos"   $MNT/playos-samples/build/hello-playos
    install -m 0755 "$SAMPLES_DIR/space-invaders" $MNT/playos-samples/build/space-invaders
fi

# ── Install compositor init script ───────────────────────────────────────────
if [ -f "$ROOT/alpine/init.d/playos-compositor" ]; then
    install -m 0755 "$ROOT/alpine/init.d/playos-compositor" \
        $MNT/etc/init.d/playos-compositor
fi

# ── Create first-boot init script ────────────────────────────────────────────
echo "==> Installing first-boot service"
install -m 0755 "$ROOT/alpine/init.d/playos-firstboot" \
    $MNT/etc/init.d/playos-firstboot

# ── Configure OpenRC runlevels ───────────────────────────────────────────────
echo "==> Configuring OpenRC runlevels"

# Helper: symlink init script into runlevel
rc_add() {
    mkdir -p "$MNT/etc/runlevels/$2"
    ln -sf "/etc/init.d/$1" "$MNT/etc/runlevels/$2/$1"
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
rc_add iwd default
rc_add networkmanager default
rc_add wpa_supplicant default

# SSH debug access
rc_add sshd default

# First-boot one-shot (runs once, deletes itself)
rc_add playos-firstboot default

# ── Create firstboot flag file ───────────────────────────────────────────────
mkdir -p $MNT/etc/playos
touch $MNT/etc/playos/firstboot

# ── Hostname ─────────────────────────────────────────────────────────────────
echo "playos" > $MNT/etc/hostname

# ── Timezone ─────────────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/UTC $MNT/etc/localtime

# ── SSH debug key ────────────────────────────────────────────────────────────
mkdir -p $MNT/root/.ssh
cat > $MNT/root/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKjUiS/ZaOaGpyGkzotL9kUnsqOTpN07h0nZBpPwsDbP playos-debug
EOF
chmod 700 $MNT/root/.ssh
chmod 600 $MNT/root/.ssh/authorized_keys

# ── Kernel cmdline (applied by bootloader) ───────────────────────────────────
mkdir -p $MNT/etc/kernel
cat > $MNT/etc/kernel/cmdline <<'EOF'
console=tty0 amdgpu.sg_display=0 quiet loglevel=3
EOF

# ── fstab ────────────────────────────────────────────────────────────────────
ROOT_UUID="${ROOT_UUID:-$(blkid -s UUID -o value "${LOOP}p2" 2>/dev/null)}"
EFI_UUID="${EFI_UUID:-$(blkid -s UUID -o value "${LOOP}p1" 2>/dev/null)}"

cat > $MNT/etc/fstab <<EOF
# /etc/fstab — PlayOS installed system
UUID=$ROOT_UUID /         ext4  defaults,noatime  0 1
UUID=$EFI_UUID  /boot/efi vfat  defaults,noatime  0 2
EOF

# ── Bootloader (systemd-boot) ─────────────────────────────────────────────────
# Install EFI stub to rootfs. Actual ESP deployment is done by
# build-iso-ubuntu.sh on the host side (nspawn --bind doesn't propagate
# sub-mounts so ESP at /boot/efi isn't visible inside the container).
echo "==> Installing systemd-boot EFI stub to rootfs"
apk --root $MNT add --no-cache systemd-boot 2>/dev/null || true

# ── Unmount + compress (only when we created the image ourselves) ────────────
if [ -n "$MUST_CLEANUP" ]; then
    echo "==> Unmounting image"
    sync
    umount "$MNT/boot/efi"
    umount "$MNT"
    losetup -d "$LOOP"
    trap - EXIT

    echo "==> Compressing with zstd"
    UNCOMPRESSED_SIZE=$(du -h "$OUT/$IMAGE_NAME.img" | cut -f1)
    zstd -T0 --rm -12 "$OUT/$IMAGE_NAME.img"
    COMPRESSED_SIZE=$(du -h "$OUT/$IMAGE_NAME.img.zst" | cut -f1)
    echo "    $UNCOMPRESSED_SIZE → $COMPRESSED_SIZE"

    echo "==> Computing SHA-256 checksum"
    sha256sum "$OUT/$IMAGE_NAME.img.zst" > "$OUT/$IMAGE_NAME.img.zst.sha256"
    echo "    $(cat $OUT/$IMAGE_NAME.img.zst.sha256)"
else
    echo "==> Disk image populated (compress + unmount handled by host wrapper)"
fi

echo "==> Disk image done: $OUT/$IMAGE_NAME.img"
