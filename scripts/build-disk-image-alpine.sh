#!/usr/bin/env bash
# build-disk-image-alpine.sh — Populate a pre-mounted disk image with Alpine Linux + PlayOS.
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
IMAGE_SIZE_MB="${PLAYOS_IMAGE_SIZE_MB:-6144}"
ESP_SIZE_MB="${PLAYOS_ESP_SIZE_MB:-512}"
ROOT_SIZE_MB="${PLAYOS_ROOT_SIZE_MB:-4096}"
IMAGE_NAME="playos-gpt-alpine-${ALPINE_BRANCH}-${ARCH}"
MNT="${DISK_MNT:-}"

# ── Initialize logging ──────────────────────────────────────────────────────
source "$ROOT/shared/logging-helpers.sh"
_log_step "Building PlayOS disk image: $IMAGE_NAME"
mkdir -p "$OUT"

# ── Phase 1: Create + partition + format + mount (only when no DISK_MNT) ──────
MUST_CLEANUP=""
if [ -z "$MNT" ]; then
    _log_info "Creating ${IMAGE_SIZE_MB} MiB sparse image"
    truncate -s "${IMAGE_SIZE_MB}M" "$OUT/$IMAGE_NAME.img"

    _log_info "Partitioning: GPT with ESP + root + data"
    sgdisk -Z "$OUT/$IMAGE_NAME.img"
    sgdisk -n "1:1M:+${ESP_SIZE_MB}M" -t 1:EF00 "$OUT/$IMAGE_NAME.img"
    sgdisk -n "2:0:+${ROOT_SIZE_MB}M" -t 2:8300 "$OUT/$IMAGE_NAME.img"
    sgdisk -n 3:0:0 -t 3:8300 "$OUT/$IMAGE_NAME.img"

    LOOP=$(losetup --find --show -P "$OUT/$IMAGE_NAME.img")
    _log_info "Loop device: $LOOP"

    _log_info "Formatting partitions"
    mkfs.vfat -F32 -n PLAYOS_EFI "${LOOP}p1"
    mkfs.ext4 -F -L playos-root "${LOOP}p2"
    mkfs.ext4 -F -L playos-data "${LOOP}p3"

    MNT="/mnt/playos-image-root"
    mkdir -p "$MNT"
    mount "${LOOP}p2" "$MNT"
    mkdir -p "$MNT/boot/efi" "$MNT/data"
    mount "${LOOP}p1" "$MNT/boot/efi"
    mount "${LOOP}p3" "$MNT/data"

    MUST_CLEANUP="yes"

    cleanup_loop() {
        _log_info "Unmounting + detaching loop device"
        sync
        mountpoint -q "$MNT/data" 2>/dev/null && umount "$MNT/data" || true
        mountpoint -q "$MNT/boot/efi" 2>/dev/null && umount "$MNT/boot/efi" || true
        mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" || true
        losetup -d "$LOOP" 2>/dev/null || true
    }
    trap cleanup_loop EXIT
else
    _log_info "Using pre-mounted disk image at $MNT"
fi

# ── Install Alpine base system ───────────────────────────────────────────────
_log_step "Installing Alpine base system"

# APK repos MUST exist before any --root install, since apk reads them from the target root
mkdir -p $MNT/etc/apk
cat > $MNT/etc/apk/repositories <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
REPOS

mkdir -p $MNT/etc/apk/keys
cp /etc/apk/keys/* $MNT/etc/apk/keys/

apk --root $MNT --initdb add --no-cache --no-progress alpine-base

# ── Install PlayOS packages ──────────────────────────────────────────────────
_log_step "Installing PlayOS system packages"
apk --root $MNT add --no-cache --no-progress \
    alpine-conf \
    bluez bluez-openrc \
    dbus dbus-openrc \
    eudev eudev-openrc \
    foot font-dejavu \
    gptfdisk \
    glfw \
    iwd iwd-openrc \
    kmod \
    libdrm \
    libinput \
    libxkbcommon \
    linux-firmware-amdgpu \
    linux-firmware-nvidia \
    linux-firmware-rtl_nic \
    linux-firmware-intel \
    linux-firmware-mediatek \
    linux-firmware-ath10k \
    linux-firmware-ath11k \
    linux-firmware-brcm \
    wireless-regdb \
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
    seatd seatd-openrc \
    wayland \
    wireplumber wireplumber-openrc \
    wlroots0.19 \
    systemd-boot \
    efibootmgr \
    util-linux

# Install kernel separately with --no-scripts: the post-install depmod trigger
# fails in a cross-root install (apk --root $MNT) because depmod looks for
# vmlinuz in the host container context, not in $MNT.  We run depmod
# manually afterwards with the correct base directory.
_log_step "Installing kernel (modules only, no post-install scripts)"
apk --root $MNT add --no-cache --no-progress --no-scripts linux-stable

KERNEL_VER=$(ls "$MNT/lib/modules/" | head -1 2>/dev/null || true)

# Install GPU firmware globally in the build container.
# mkinitfs does NOT apply -b to firmware file lookups — it always reads
# from /lib/firmware/ in the running environment.  The --root install above
# placed firmware at $MNT/lib/firmware/ (correct for the installed system),
# but mkinitfs needs it at /lib/firmware/ in the build container to include
# it in the initramfs.  Without this, amdgpu/nvidia devices black-screen.
_log_step "Installing GPU firmware in build container (for initramfs)"
apk add --no-cache --no-progress linux-firmware-amdgpu linux-firmware-nvidia linux-firmware-intel

# Install hid-asus-ally kernel module (ROG Ally HID driver), built by
# build-hid-asus-ally.sh earlier in the nspawn session.  Must happen
# after kernel install (so $MNT/lib/modules/$KERNEL_VER exists) but
# before depmod + initramfs (so the module is included in the initramfs).
HID_KO="/var/tmp/playos-build/hid-asus-ally/hid-asus-ally.ko"
if [ -f "$HID_KO" ] && [ -n "$KERNEL_VER" ]; then
    _log_step "Installing hid-asus-ally kernel module"
    MOD_DEST="$MNT/lib/modules/$KERNEL_VER/kernel/drivers/hid"
    mkdir -p "$MOD_DEST"
    cp "$HID_KO" "$MOD_DEST/hid-asus-ally.ko"
    _log_info "hid-asus-ally.ko installed to $MOD_DEST"
elif [ ! -f "$HID_KO" ]; then
    _log_warn "hid-asus-ally.ko not found — skipping (non-fatal)"
fi

if [ -n "$KERNEL_VER" ] && [ -d "$MNT/lib/modules/$KERNEL_VER" ]; then
    _log_step "Generating module dependencies for $KERNEL_VER"
    depmod -b "$MNT" "$KERNEL_VER" 2>/dev/null && \
        _log_success "depmod OK" || \
        _log_warn "depmod failed (non-fatal — initramfs will regenerate on boot)"

    # Install GPU mkinitfs feature files — required for AMD/NVIDIA GPU
    # firmware and kernel modules in the initramfs.  The ISO build
    # (build-alpine-iso.sh, Phase 3) installs these globally, but the
    # disk-image build runs earlier (Phase 1) — source them directly
    # from the workspace bind mount.
    _log_step "Installing GPU mkinitfs feature files"
    mkdir -p "$MNT/etc/mkinitfs/features.d"
    for feat in amdgpu.modules amdgpu-firmware.files nvidia.modules nvidia-firmware.files; do
        SRC="/workspace/alpine/$feat"
        if [ -f "$SRC" ]; then
            cp "$SRC" "$MNT/etc/mkinitfs/features.d/$feat"
            _log_info "$feat"
        else
            _log_warn "$SRC not found — GPU may not initialize on disk boot"
        fi
    done

    # Append GPU features to the default mkinitfs.conf so the initramfs
    # includes amdgpu/nvidia modules + firmware.  Without this, the ROG Ally
    # (and any AMD dGPU device) will black-screen because the amdgpu driver
    # cannot bind without firmware present in early boot.
    if ! grep -q 'amdgpu' "$MNT/etc/mkinitfs/mkinitfs.conf" 2>/dev/null; then
        sed -i 's/^features="\(.*\)"/features="\1 amdgpu amdgpu-firmware nvidia nvidia-firmware"/' \
            "$MNT/etc/mkinitfs/mkinitfs.conf"
        _log_success "GPU features appended to mkinitfs.conf"
    fi

    # Drop the 'kms' feature: it loads amdgpu in early initramfs, which
    # black-screens the ROG Ally.  The LiveUSB (no kms) boots fine — GPU
    # drivers load later via udev, matching the proven-good live behavior.
    if grep -q ' kms ' "$MNT/etc/mkinitfs/mkinitfs.conf" 2>/dev/null; then
        sed -i 's/ kms / /' "$MNT/etc/mkinitfs/mkinitfs.conf"
        _log_success "kms feature removed from mkinitfs.conf"
    fi

    _log_step "Generating initramfs for $KERNEL_VER"
    # NOTE: -F flag in mkinitfs 3.14 expects an argument (features string),
    # NOT a boolean "force" flag.  Using -F without an argument causes
    # mkinitfs to consume the next flag (-c) as the features value,
    # dropping config and treating the config path as the kernel version.
    # GPU features are already in mkinitfs.conf (via sed) and features.d
    # (via -P), so -F is unnecessary.
    mkinitfs \
        -b "$MNT" \
        -c "$MNT/etc/mkinitfs/mkinitfs.conf" \
        -P "$MNT/etc/mkinitfs/features.d" \
        -o "$MNT/boot/initramfs-stable" \
        "$KERNEL_VER"
    test -s "$MNT/boot/initramfs-stable"

    # Verify GPU firmware landed in the initramfs.
    # Note: mkinitfs may use lz4 or xz compression depending on config.
    # Detect compression and decompress accordingly.
    _log_step "Verifying initramfs firmware inclusion"
    INITRAMFS="$MNT/boot/initramfs-stable"

    # Detect initramfs compression by reading magic bytes.
    # gzip: 0x1F 0x8B, xz: 0xFD 0x37 0x7A, lz4: 0x04 0x22 0x4D 0x18
    magic=$(od -A n -t x1 -N 4 "$INITRAMFS" | tr -d ' ')
    case "$magic" in
        1f8b*)       DECOMP="gunzip -c"  ; LABEL="gzip" ;;
        fd377a58*)   DECOMP="xzcat"      ; LABEL="xz"   ;;
        04224d18*)   DECOMP="lz4cat"     ; LABEL="lz4"  ;;
        30373037*)   DECOMP="cat"        ; LABEL="cpio (uncompressed)" ;;
        *)           DECOMP="gunzip -c"  ; LABEL="unknown (trying gzip)" ;;
    esac
    echo "    initramfs format: $LABEL"

    # Cache the decompressed file listing for multiple checks.
    INITRAMFS_LISTING=$(mktemp)
    trap 'rm -f "$INITRAMFS_LISTING"' EXIT
    set +o pipefail
    $DECOMP "$INITRAMFS" 2>/dev/null | cpio -t 2>/dev/null > "$INITRAMFS_LISTING"
    set -o pipefail

    # Check amdgpu firmware
    if grep -q 'lib/firmware/amdgpu/' "$INITRAMFS_LISTING"; then
        AMDFW_COUNT=$(grep -c 'lib/firmware/amdgpu/' "$INITRAMFS_LISTING" || true)
        echo "    amdgpu firmware: OK ($AMDFW_COUNT files)"
    else
        echo "    WARNING: amdgpu firmware MISSING from initramfs — ROG Ally will black-screen"
        echo "    hint: mkinitfs -F should auto-include firmware; check /lib/firmware/amdgpu/ exists"
    fi

    # Check nvidia firmware
    if grep -q 'lib/firmware/nvidia/' "$INITRAMFS_LISTING"; then
        NVFW_COUNT=$(grep -c 'lib/firmware/nvidia/' "$INITRAMFS_LISTING" || true)
        echo "    nvidia firmware: OK ($NVFW_COUNT files)"
    else
        echo "    nvidia firmware: not found (non-critical for AMD GPUs)"
    fi

    # Show first 20 files on any failure for diagnostics
    if ! grep -q 'lib/firmware/amdgpu/' "$INITRAMFS_LISTING"; then
        echo "    first 20 files in initramfs:"
        head -20 "$INITRAMFS_LISTING" | sed 's/^/        /'
    fi
    rm -f "$INITRAMFS_LISTING"
else
    _log_error "kernel modules were not installed; cannot generate initramfs"
    exit 1
fi

# ── Copy PlayOS custom binaries ──────────────────────────────────────────────
_log_step "Copying PlayOS binaries"

# Compositor
if [ -f /usr/bin/playos-compositor ]; then
    install -m 0755 /usr/bin/playos-compositor $MNT/usr/bin/playos-compositor
fi

# Shell
if [ -f /usr/bin/playos-shell ]; then
    install -m 0755 /usr/bin/playos-shell $MNT/usr/bin/playos-shell
fi

# Shared libraries (shell links against these at runtime)
if [ -f /usr/lib/libraylib.so.600 ]; then
    cp -a /usr/lib/libraylib.so.600 $MNT/usr/lib/
    ln -sf libraylib.so.600 $MNT/usr/lib/libraylib.so
fi
if [ -f /usr/lib/libglfw.so.3 ]; then
    cp -a /usr/lib/libglfw.so.3 $MNT/usr/lib/
fi

# ── Copy samples ─────────────────────────────────────────────────────────────
SAMPLES_DIR="/workspace/.build/samples-out"
if [ -d "$SAMPLES_DIR" ] && [ -f "$SAMPLES_DIR/hello-playos" ]; then
    _log_step "Bundling PlayOS samples from $SAMPLES_DIR"
    mkdir -p $MNT/playos-samples/build
    install -m 0755 "$SAMPLES_DIR/hello-playos"   $MNT/playos-samples/build/hello-playos
    install -m 0755 "$SAMPLES_DIR/space-invaders" $MNT/playos-samples/build/space-invaders
    install -m 0755 "$SAMPLES_DIR/input-debug"    $MNT/playos-samples/build/input-debug
    _log_success "Samples bundled: $(ls $MNT/playos-samples/build/)"
elif [ ! -d "$SAMPLES_DIR" ]; then
    _log_warn "Samples directory $SAMPLES_DIR not found — skipping sample bundle"
elif [ ! -f "$SAMPLES_DIR/hello-playos" ]; then
    _log_warn "hello-playos not found in $SAMPLES_DIR — skipping sample bundle"
fi

# ── Deploy device profiles ───────────────────────────────────────────────────
# Copy from playos-reference-devices sibling repo if available.
REFDEV_DIR="${PLAYOS_REFERENCE_DEVICES:-/mnt/playos-reference-devices}"
ROG_ALLY_PROFILE="$REFDEV_DIR/rog-ally/device-profile.toml"
if [ -f "$ROG_ALLY_PROFILE" ]; then
    _log_step "Deploying device profiles"
    mkdir -p $MNT/etc/playos/device-profiles
    cp "$ROG_ALLY_PROFILE" $MNT/etc/playos/device-profiles/rog-ally.toml
    echo "    rog-ally profile installed"
    # Also install into the build container rootfs: the ISO build phase runs
    # from this same nspawn rootfs, and genapkovl-playos.sh bundles profiles
    # from here into the apkovl (it has no access to the refdev bind mount).
    mkdir -p /etc/playos/device-profiles
    cp "$ROG_ALLY_PROFILE" /etc/playos/device-profiles/rog-ally.toml
fi

# ── Install compositor init script ───────────────────────────────────────────
if [ -f "$ROOT/alpine/init.d/playos-compositor" ]; then
    install -m 0755 "$ROOT/alpine/init.d/playos-compositor" \
        $MNT/etc/init.d/playos-compositor
fi

# ── Install async trigger init script ────────────────────────────────────────
if [ -f "$ROOT/alpine/init.d/playos-async-trigger" ]; then
    install -m 0755 "$ROOT/alpine/init.d/playos-async-trigger" \
        $MNT/etc/init.d/playos-async-trigger
fi

# ── Install PlayOS networkmanager init script ─────────────────────────────────
# Replaces the Alpine-packaged one with iwd D-Bus readiness polling so NM
# doesn't start before iwd registers its D-Bus name (see §7.3 of
# docs/boot-analysis-rog-ally-2026-07-30.md).
if [ -f "$ROOT/alpine/init.d/networkmanager" ]; then
    install -m 0755 "$ROOT/alpine/init.d/networkmanager" \
        $MNT/etc/init.d/networkmanager
fi

# ── Create first-boot init script ────────────────────────────────────────────
_log_step "Installing first-boot service"
install -m 0755 "$ROOT/alpine/init.d/playos-firstboot" \
    $MNT/etc/init.d/playos-firstboot

# ── Configure OpenRC runlevels ───────────────────────────────────────────────
_log_step "Configuring OpenRC runlevels"

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
rc_add dbus playos-visual
rc_add seatd playos-visual
rc_add playos-compositor playos-visual
rc_add playos-async-trigger playos-visual

# WiFi backend — iwd for NetworkManager, started after first frame.
# iwd runs as a service; our custom init.d/networkmanager polls for
# iwd's D-Bus name readiness before starting NM.  See
# alpine/init.d/networkmanager and docs/boot-analysis-rog-ally-*.md.
rc_add iwd playos-async
rc_add networkmanager playos-async
rc_add bluetooth playos-async

# playos-usb-gadget removed — g_serial kernel module unavailable; ROG Ally USB-C is host-only

# ── NetworkManager configuration ──────────────────────────────────────────────
_log_step "Configuring NetworkManager"

# Custom init.d/networkmanager polls for iwd D-Bus readiness; see above.

mkdir -p $MNT/etc/NetworkManager/conf.d
cat > $MNT/etc/NetworkManager/conf.d/playos.conf <<'EOF'
[main]
plugins=keyfile
dhcp=internal

[device]
wifi.backend=iwd
wifi.iwd.autoconnect=yes

[connectivity]
enabled=false
EOF

# Default wired connection profile — auto-connects ANY ethernet device
# (eth0, enx*, enp*, usb*, ...). No interface-name restriction.
mkdir -p $MNT/etc/NetworkManager/system-connections
cat > $MNT/etc/NetworkManager/system-connections/00-wired-dhcp.nmconnection <<'EOF'
[connection]
id=wired-dhcp
type=ethernet
autoconnect=true
autoconnect-priority=100

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 $MNT/etc/NetworkManager/system-connections/00-wired-dhcp.nmconnection

# ── WiFi auto-connect profile ────────────────────────────────────────────────
# Set PLAYOS_WIFI_SSID + PLAYOS_WIFI_PSK at build time to bake a persistent
# WiFi connection into the disk image.  This allows SSH access on first boot
# even when the compositor fails (black screen debugging).
if [ -n "${PLAYOS_WIFI_SSID:-}" ] && [ -n "${PLAYOS_WIFI_PSK:-}" ]; then
    _log_step "Creating WiFi auto-connect profile: $PLAYOS_WIFI_SSID"
    cat > "$MNT/etc/NetworkManager/system-connections/01-wifi-auto.nmconnection" <<WIFIEOF
[connection]
id=${PLAYOS_WIFI_SSID}
type=wifi
autoconnect=true
autoconnect-priority=50
autoconnect-retries=10
auth-retries=5

[wifi]
ssid=${PLAYOS_WIFI_SSID}
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=${PLAYOS_WIFI_PSK}

[ipv4]
method=auto
WIFIEOF
    chmod 600 "$MNT/etc/NetworkManager/system-connections/01-wifi-auto.nmconnection"

    # Also bake an iwd PSK profile so iwd handles BSSID selection and
    # retry natively — more robust than NM's iwd backend after 4-way
    # handshake timeouts on mesh nodes.
    mkdir -p "$MNT/var/lib/iwd"
    cat > "$MNT/var/lib/iwd/${PLAYOS_WIFI_SSID}.psk" <<IWDEOF
[Security]
Passphrase=${PLAYOS_WIFI_PSK}
IWDEOF
    chmod 600 "$MNT/var/lib/iwd/${PLAYOS_WIFI_SSID}.psk"
    _log_success "WiFi profile and iwd PSK profile baked into disk image"
fi

# SSH debug access
rc_add sshd playos-async

# First-boot one-shot (runs once, deletes itself)
rc_add playos-firstboot playos-visual

# ── Create firstboot flag file ───────────────────────────────────────────────
mkdir -p $MNT/etc/playos
touch $MNT/etc/playos/firstboot

# ── Hostname ─────────────────────────────────────────────────────────────────
echo "playos" > $MNT/etc/hostname

# ── OpenRC boot logging → /var/log/rc.log (post-mortem evidence for boot stalls)
echo 'rc_logger="YES"' >> $MNT/etc/rc.conf

# ── Timezone ─────────────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/UTC $MNT/etc/localtime

# ── SSH debug key ────────────────────────────────────────────────────────────
mkdir -p $MNT/root/.ssh
SSH_PUBKEY=""
if [ -n "${PLAYOS_SSH_PUBKEY:-}" ]; then
    SSH_PUBKEY="$PLAYOS_SSH_PUBKEY"
elif [ -f "${HOME}/.ssh/id_ed25519.pub" ]; then
    SSH_PUBKEY="$(cat "${HOME}/.ssh/id_ed25519.pub")"
elif [ -f "${HOME}/.ssh/id_rsa.pub" ]; then
    SSH_PUBKEY="$(cat "${HOME}/.ssh/id_rsa.pub")"
else
    SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKjUiS/ZaOaGpyGkzotL9kUnsqOTpN07h0nZBpPwsDbP playos-debug"
fi
echo "$SSH_PUBKEY" > $MNT/root/.ssh/authorized_keys
chmod 700 $MNT/root/.ssh
chmod 600 $MNT/root/.ssh/authorized_keys

# ── Kernel cmdline (applied by bootloader) ───────────────────────────────────
mkdir -p $MNT/etc/kernel
cat > $MNT/etc/kernel/cmdline <<'EOF'
console=tty0 console=ttyS0 amdgpu.sg_display=0 loglevel=7 cfg80211.ieee80211_regdom=GR
EOF

# ── Data partition directories ────────────────────────────────────────────────
_log_step "Creating /data directory structure"
mkdir -p $MNT/data/games $MNT/data/saves $MNT/data/config

# foot terminal in the Library — fullscreen readable terminal on all
# displays (debug console without a VT).
ln -sf /usr/bin/foot $MNT/data/games/foot

# ── fstab ────────────────────────────────────────────────────────────────────
# In nspawn mode (DISK_MNT pre-set), UUIDs come from the host via env vars.
# In standalone mode, LOOP is defined and we can query the loop device directly.
if [ -n "${LOOP:-}" ] && [ -b "${LOOP}p2" ] 2>/dev/null; then
    ROOT_UUID="${ROOT_UUID:-$(blkid -s UUID -o value "${LOOP}p2" 2>/dev/null)}"
    EFI_UUID="${EFI_UUID:-$(blkid -s UUID -o value "${LOOP}p1" 2>/dev/null)}"
    DATA_UUID="${DATA_UUID:-$(blkid -s UUID -o value "${LOOP}p3" 2>/dev/null)}"
    ROOT_PARTUUID="${ROOT_PARTUUID:-$(blkid -s PARTUUID -o value "${LOOP}p2" 2>/dev/null)}"
fi

cat > $MNT/etc/fstab <<EOF
# /etc/fstab — PlayOS installed system
UUID=$ROOT_UUID /         ext4  defaults,noatime  0 1
UUID=$EFI_UUID  /boot/efi vfat  defaults,noatime  0 2
UUID=$DATA_UUID /data     ext4  defaults,noatime  0 2
EOF

# ── Bootloader: systemd-boot installation ────────────────────────────────────
# systemd-boot package is already installed above (apk add).  Now deploy it to
# the ESP when the ESP is directly accessible.  Inside nspawn with --bind the
# ESP sub-mount is invisible, so we skip; the host wrapper (build-iso-ubuntu.sh)
# handles ESP deployment externally in that case.
_log_step "Installing systemd-boot to ESP"
STUB="$MNT/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
if mountpoint -q "$MNT/boot/efi" 2>/dev/null && [ -f "$STUB" ]; then
    mkdir -p "$MNT/boot/efi/EFI/BOOT" \
             "$MNT/boot/efi/EFI/systemd" \
             "$MNT/boot/efi/loader/entries"

    cp "$STUB" "$MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
    cp "$STUB" "$MNT/boot/efi/EFI/systemd/systemd-bootx64.efi"

    cat > "$MNT/boot/efi/loader/entries/playos.conf" <<CONFENTRY
title   PlayOS
linux   /vmlinuz-stable
initrd  /initramfs-stable
options root=UUID=${ROOT_UUID} rootfstype=ext4 rw console=tty0 console=ttyS0 amdgpu.sg_display=0 rootdelay=2 loglevel=7 softlevel=playos-visual
CONFENTRY

    cat > "$MNT/boot/efi/loader/loader.conf" <<LOADERCONF
default playos.conf
timeout 0
console-mode keep
LOADERCONF

    cp "$MNT/boot/vmlinuz-stable"   "$MNT/boot/efi/vmlinuz-stable"
    cp "$MNT/boot/initramfs-stable" "$MNT/boot/efi/initramfs-stable"
    _log_success "systemd-boot installed to ESP"
else
    _log_info "ESP not directly accessible (nspawn mode) — host wrapper will install bootloader"
fi

# ── Unmount + compress (only when we created the image ourselves) ────────────
if [ -n "$MUST_CLEANUP" ]; then
    _log_step "Unmounting image"
    sync
    umount "$MNT/data"
    umount "$MNT/boot/efi"
    umount "$MNT"
    losetup -d "$LOOP"
    trap - EXIT

    _log_step "Compressing with zstd"
    UNCOMPRESSED_SIZE=$(du -h "$OUT/$IMAGE_NAME.img" | cut -f1)
    zstd -T0 --rm -12 "$OUT/$IMAGE_NAME.img"
    COMPRESSED_SIZE=$(du -h "$OUT/$IMAGE_NAME.img.zst" | cut -f1)
    _log_success "$UNCOMPRESSED_SIZE → $COMPRESSED_SIZE"

    _log_step "Computing SHA-256 checksum"
    ( cd "$OUT" && sha256sum "$IMAGE_NAME.img.zst" > "$IMAGE_NAME.img.zst.sha256" )
    _log_info "$(cat $OUT/$IMAGE_NAME.img.zst.sha256)"
else
    _log_info "Disk image populated (compress + unmount handled by host wrapper)"
fi

_log_success "Disk image done: $OUT/$IMAGE_NAME.img"
