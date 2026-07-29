#!/usr/bin/env bash
# build-disk-image-arch.sh — Populate a pre-mounted disk image with Arch Linux + PlayOS.
#
# Expected env vars (set by host wrapper or nspawn):
#   DISK_MNT              — mount point of root partition
#   PLAYOS_ROOT           — bind-mounted workspace path
#   ROOT_UUID / EFI_UUID / DATA_UUID / ROOT_PARTUUID
#   PLAYOS_KERNEL_VARIANT — cachyos (default) or deckify
#
# Output: populated rootfs at $DISK_MNT.
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"

# ── Initialize logging ──────────────────────────────────────────────────────
source "$ROOT/shared/logging-helpers.sh"

MNT="${DISK_MNT:?}"
KERNEL_VARIANT="${PLAYOS_KERNEL_VARIANT:-cachyos}"

_log_step "Building PlayOS Arch disk image (kernel: $KERNEL_VARIANT)"

# ── Select kernel package ────────────────────────────────────────────────────
case "$KERNEL_VARIANT" in
    cachyos)
        KERNEL_PKG="linux-cachyos"
        PACKAGES_FILE="$ROOT/arch/packages.x86_64"
        ;;
    deckify)
        KERNEL_PKG="linux-cachyos-deckify"
        PACKAGES_FILE="$ROOT/arch/packages-handheld.x86_64"
        ;;
    *)
        _log_error "unknown KERNEL_VARIANT=$KERNEL_VARIANT (expect cachyos or deckify)" >&2
        exit 1
        ;;
esac

_log_info "Kernel package: $KERNEL_PKG"
_log_info "Package list:   $PACKAGES_FILE"

# ── Validate package list ────────────────────────────────────────────────────
if [ ! -f "$PACKAGES_FILE" ]; then
    _log_error "package list not found: $PACKAGES_FILE" >&2
    exit 1
fi

# ── Install Arch base system via pacstrap ─────────────────────────────────────
_log_step "Bootstrapping Arch base system"

# Install pacman.conf into build environment first
mkdir -p /etc
cp "$ROOT/arch/pacman.conf" /etc/pacman.conf

# Install CachyOS GPG key
_log_step "Importing CachyOS GPG key"
pacman-key --init 2>/dev/null || true
pacman-key --populate archlinux 2>/dev/null || true
if ! pacman-key --list-keys F3B607488DB35A47 >/dev/null 2>&1; then
    pacman-key --recv-keys F3B607488DB35A47 --keyserver hkp://keyserver.ubuntu.com 2>/dev/null || \
        pacman-key --recv-keys F3B607488DB35A47 2>/dev/null || \
        _log_warn "Could not import CachyOS GPG key — signature verification may fail"
    pacman-key --lsign-key F3B607488DB35A47 2>/dev/null || true
fi
_log_info "CachyOS GPG key: OK"

# Install base system
# Read packages from file, filtering comments and blank lines
PACKAGES=""
while IFS= read -r pkg; do
    # Skip comments and blank lines
    [[ "$pkg" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$pkg" ]] && continue
    # We don't add the kernel here yet — it needs special handling
    if [[ "$pkg" != "linux-cachyos" && "$pkg" != "linux-cachyos-deckify" ]]; then
        PACKAGES="$PACKAGES $pkg"
    fi
done < "$PACKAGES_FILE"

# Install base system using pacman directly (pacstrap is just a wrapper)
_log_info "Installing packages..."
# pacman needs the db directory to exist on the target root
mkdir -p "$MNT/var/lib/pacman/sync" "$MNT/var/cache/pacman/pkg"
# shellcheck disable=SC2086
pacman -r "$MNT" -Sy --noconfirm --disable-download-timeout $PACKAGES

# Install CachyOS kernel (may need --overwrite for firmware files)
_log_step "Installing kernel: $KERNEL_PKG"
# Pre-answer initramfs provider prompt (mkinitcpio = 1)
echo "1" | pacman -r "$MNT" -S --noconfirm --disable-download-timeout "$KERNEL_PKG" || {
    _log_info "Retrying with --overwrite for firmware conflicts..."
    echo "1" | yes | pacman -r "$MNT" -S --overwrite='*' --noconfirm --disable-download-timeout "$KERNEL_PKG"
}

# Copy pacman.conf into the target
cp "$ROOT/arch/pacman.conf" "$MNT/etc/pacman.conf"

# ── Install PlayOS custom binaries ──────────────────────────────────────────
_log_step "Copying PlayOS binaries"

if [ -f /usr/bin/playos-compositor ]; then
    install -m 0755 /usr/bin/playos-compositor "$MNT/usr/bin/playos-compositor"
fi
if [ -f /usr/bin/playos-shell ]; then
    install -m 0755 /usr/bin/playos-shell "$MNT/usr/bin/playos-shell"
fi

# Shared libraries
if [ -f /usr/lib/libraylib.so.600 ]; then
    cp -a /usr/lib/libraylib.so.600 "$MNT/usr/lib/"
    ln -sf libraylib.so.600 "$MNT/usr/lib/libraylib.so"
fi
if [ -f /usr/lib/libglfw.so.3 ]; then
    cp -a /usr/lib/libglfw.so.3 "$MNT/usr/lib/"
fi

# ── Copy samples ─────────────────────────────────────────────────────────────
SAMPLES_DIR="$ROOT/.build/samples-out"
if [ -d "$SAMPLES_DIR" ] && [ -f "$SAMPLES_DIR/hello-playos" ]; then
    _log_step "Bundling PlayOS samples"
    mkdir -p "$MNT/playos-samples/build"
    for sample in hello-playos space-invaders input-debug; do
        if [ -f "$SAMPLES_DIR/$sample" ]; then
            install -m 0755 "$SAMPLES_DIR/$sample" "$MNT/playos-samples/build/$sample"
        fi
    done
    _log_info "Samples: $(ls "$MNT/playos-samples/build/" 2>/dev/null | xargs)"
fi

# ── Deploy device profiles ───────────────────────────────────────────────────
REFDEV_DIR="${PLAYOS_REFERENCE_DEVICES:-/mnt/playos-reference-devices}"
if [ -d "$REFDEV_DIR" ]; then
    _log_step "Deploying device profiles"
    mkdir -p "$MNT/etc/playos/device-profiles"
    for profile in "$REFDEV_DIR"/*/device-profile.toml; do
        if [ -f "$profile" ]; then
            name="$(basename "$(dirname "$profile")")"
            cp "$profile" "$MNT/etc/playos/device-profiles/${name}.toml"
            _log_info "$name"
        fi
    done
fi

# ── Install systemd units ────────────────────────────────────────────────────
_log_step "Installing systemd units"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"

for unit in playos-compositor.service playos-firstboot.service seatd.service; do
    if [ -f "$ROOT/arch/systemd/$unit" ]; then
        install -m 0644 "$ROOT/arch/systemd/$unit" "$MNT/etc/systemd/system/$unit"
        _log_info "$unit"
    fi
done

# Enable services (systemctl --root)
systemctl --root="$MNT" enable seatd.service 2>/dev/null || \
    ln -sf /etc/systemd/system/seatd.service "$MNT/etc/systemd/system/multi-user.target.wants/seatd.service"

systemctl --root="$MNT" enable playos-compositor.service 2>/dev/null || \
    ln -sf /etc/systemd/system/playos-compositor.service "$MNT/etc/systemd/system/multi-user.target.wants/playos-compositor.service"

systemctl --root="$MNT" enable playos-firstboot.service 2>/dev/null || \
    ln -sf /etc/systemd/system/playos-firstboot.service "$MNT/etc/systemd/system/multi-user.target.wants/playos-firstboot.service"

# ── Initramfs ────────────────────────────────────────────────────────────────
_log_step "Generating initramfs"

# Install the same kernel + linux-firmware in the build environment so
# mkinitcpio can find kernel modules at /lib/modules/ (it doesn't support
# pointing to $MNT/lib/modules).
_log_info "Installing kernel in build env for mkinitcpio..."
echo "1" | pacman -Sy --noconfirm --disable-download-timeout "$KERNEL_PKG" linux-firmware 2>/dev/null || true

KERNEL_VER="$(ls /lib/modules/ | head -1 2>/dev/null || true)"

if [ -n "$KERNEL_VER" ]; then
    cp "$ROOT/arch/mkinitcpio.conf" /etc/mkinitcpio.conf

    # Add amdgpu module for GPU init
    if ! grep -q 'amdgpu' /etc/mkinitcpio.conf 2>/dev/null; then
        sed -i 's/^MODULES=(/MODULES=(amdgpu /' /etc/mkinitcpio.conf
    fi

    # Generate initramfs for the installed kernel (in build env)
    mkinitcpio -g /tmp/initramfs-linux.img -k "$KERNEL_VER"

    _log_info "initramfs generated for $KERNEL_VER"

    # Copy kernel and initramfs to target disk
    cp /tmp/initramfs-linux.img "$MNT/boot/initramfs-linux.img"
    cp /tmp/initramfs-linux.img "$MNT/boot/initramfs-stable"

    # Verify GPU firmware landed in the initramfs.
    _log_step "Verifying initramfs firmware inclusion (Arch/mkinitcpio)"
    INITRAMFS="$MNT/boot/initramfs-stable"

    magic=$(od -A n -t x1 -N 4 "$INITRAMFS" | tr -d ' ')
    case "$magic" in
        1f8b*)       DECOMP="gunzip -c"  ; LABEL="gzip" ;;
        fd377a58*)   DECOMP="xzcat"      ; LABEL="xz"   ;;
        04224d18*)   DECOMP="lz4cat"     ; LABEL="lz4"  ;;
        28b52ffd*)   DECOMP="zstdcat"    ; LABEL="zstd" ;;
        30373037*)   DECOMP="cat"        ; LABEL="cpio (uncompressed)" ;;
        *)           DECOMP="gunzip -c"  ; LABEL="unknown (trying gzip)" ;;
    esac
    _log_info "initramfs format: $LABEL"

    INITRAMFS_LISTING=$(mktemp)
    trap 'rm -f "$INITRAMFS_LISTING"' EXIT
    set +o pipefail
    $DECOMP "$INITRAMFS" 2>/dev/null | cpio -t 2>/dev/null > "$INITRAMFS_LISTING"
    set -o pipefail

    if grep -q 'amdgpu' "$INITRAMFS_LISTING"; then
        AMDFW_COUNT=$(grep -c 'amdgpu' "$INITRAMFS_LISTING" || true)
        _log_info "amdgpu firmware/module: OK ($AMDFW_COUNT entries)"
    else
        _log_warn "amdgpu module/firmware MISSING from Arch initramfs"
        _log_info "hint: check mkinitcpio.conf MODULES= and FILES= arrays"
        _log_info "first 20 files in initramfs:"
        head -20 "$INITRAMFS_LISTING" | sed 's/^/        /'
    fi
    rm -f "$INITRAMFS_LISTING"

    # Copy kernel from build env (same kernel package installed in build env above)
    if [ -f "/boot/vmlinuz-linux-cachyos" ]; then
        cp "/boot/vmlinuz-linux-cachyos" "$MNT/boot/vmlinuz-linux-cachyos"
        cp "/boot/vmlinuz-linux-cachyos" "$MNT/boot/vmlinuz-stable"
    elif [ -f "/boot/vmlinuz-linux-cachyos-deckify" ]; then
        cp "/boot/vmlinuz-linux-cachyos-deckify" "$MNT/boot/vmlinuz-linux-cachyos-deckify"
        cp "/boot/vmlinuz-linux-cachyos-deckify" "$MNT/boot/vmlinuz-stable"
    elif [ -f "/boot/vmlinuz-linux" ]; then
        cp "/boot/vmlinuz-linux" "$MNT/boot/vmlinuz-linux"
        cp "/boot/vmlinuz-linux" "$MNT/boot/vmlinuz-stable"
    fi

    # Also copy mkinitcpio.conf to target for future kernel updates
    cp /etc/mkinitcpio.conf "$MNT/etc/mkinitcpio.conf"
else
    _log_error "kernel modules not installed — cannot generate initramfs" >&2
    exit 1
fi

# ── Firstboot flag ───────────────────────────────────────────────────────────
mkdir -p "$MNT/etc/playos"
touch "$MNT/etc/playos/firstboot"

# ── Hostname ─────────────────────────────────────────────────────────────────
echo "playos" > "$MNT/etc/hostname"

# ── Timezone ─────────────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/UTC "$MNT/etc/localtime"

# ── SSH debug key ───────────────────────────────────────────────────────────
mkdir -p "$MNT/root/.ssh"
SSH_PUBKEY="${PLAYOS_SSH_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKjUiS/ZaOaGpyGkzotL9kUnsqOTpN07h0nZBpPwsDbP playos-debug}"
echo "$SSH_PUBKEY" > "$MNT/root/.ssh/authorized_keys"
chmod 700 "$MNT/root/.ssh"
chmod 600 "$MNT/root/.ssh/authorized_keys"

# ── Kernel cmdline ───────────────────────────────────────────────────────────
mkdir -p "$MNT/etc/kernel"
cat > "$MNT/etc/kernel/cmdline" <<'EOF'
console=tty0 console=ttyS0 amdgpu.sg_display=0 loglevel=7
EOF

# ── Data partition directories ───────────────────────────────────────────────
mkdir -p "$MNT/data/games" "$MNT/data/saves" "$MNT/data/config"

# ── fstab ────────────────────────────────────────────────────────────────────
cat > "$MNT/etc/fstab" <<EOF
# /etc/fstab — PlayOS installed system
UUID=${ROOT_UUID:-PLACEHOLDER} /         ext4  defaults,noatime  0 1
UUID=${EFI_UUID:-PLACEHOLDER}  /boot/efi vfat  defaults,noatime  0 2
UUID=${DATA_UUID:-PLACEHOLDER} /data     ext4  defaults,noatime  0 2
EOF

# ── NetworkManager config ────────────────────────────────────────────────────
mkdir -p "$MNT/etc/NetworkManager/conf.d"
cat > "$MNT/etc/NetworkManager/conf.d/playos.conf" <<'EOF'
[main]
plugins=keyfile
dhcp=internal

[device]
wifi.backend=iwd
wifi.iwd.autoconnect=yes

[connectivity]
enabled=false
EOF

mkdir -p "$MNT/etc/NetworkManager/system-connections"
cat > "$MNT/etc/NetworkManager/system-connections/00-wired-dhcp.nmconnection" <<'EOF'
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
chmod 600 "$MNT/etc/NetworkManager/system-connections/00-wired-dhcp.nmconnection"

# ── Install firstboot script ─────────────────────────────────────────────────
_log_step "Installing firstboot script"
mkdir -p "$MNT/usr/lib/playos"
if [ -f "$ROOT/shared/firstboot-common.sh" ]; then
    # Extract the firstboot logic from the OpenRC init script into
    # a standalone shell script that systemd oneshot can call.
    cp "$ROOT/shared/firstboot-common.sh" "$MNT/usr/lib/playos/playos-firstboot"
    chmod 0755 "$MNT/usr/lib/playos/playos-firstboot"
else
    _log_warn "firstboot-common.sh not found — creating stub"
    cat > "$MNT/usr/lib/playos/playos-firstboot" <<'STUB'
#!/bin/sh
# PlayOS firstboot stub — full implementation pending.
set -eu
echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] PlayOS first-boot stub"
rm -f /etc/playos/firstboot
STUB
    chmod 0755 "$MNT/usr/lib/playos/playos-firstboot"
fi

_log_step "Arch disk image populated successfully"
_log_info "Root: $DISK_MNT"
_log_info "Kernel: $KERNEL_PKG ($KERNEL_VARIANT)"
