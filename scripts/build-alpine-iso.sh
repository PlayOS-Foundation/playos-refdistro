#!/usr/bin/env bash
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
OUT="$ROOT/out"

# ── Initialize logging ──────────────────────────────────────────────────────
source "$ROOT/shared/logging-helpers.sh"
WORK="${PLAYOS_WORKDIR:-/var/tmp/playos-mkimage}"
APORTS="${PLAYOS_APORTS_DIR:-/var/cache/playos-aports}"
APORTS_BRANCH="${PLAYOS_APORTS_BRANCH:-3.24-stable}"
TAG="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"

if [[ "$TAG" == "edge" ]]; then
    _log_error "unpinned Alpine edge builds are forbidden"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$OUT" "$WORK"

# Ensure git trusts the aports directory (ownership may differ in nspawn)
git config --global --add safe.directory "$APORTS" 2>/dev/null || true

if [[ ! -d "$APORTS/.git" ]]; then
    git clone --depth 1 --branch "$APORTS_BRANCH"         https://gitlab.alpinelinux.org/alpine/aports.git "$APORTS"
else
    git -C "$APORTS" fetch --depth 1 origin "$APORTS_BRANCH"
    git -C "$APORTS" checkout --force --detach FETCH_HEAD
    git -C "$APORTS" clean -fd
fi

install -m 0755 "$ROOT/alpine/mkimg.playos.sh"     "$APORTS/scripts/mkimg.playos.sh"
install -m 0755 "$ROOT/alpine/genapkovl-playos.sh"     "$APORTS/genapkovl-playos.sh"
install -m 0644 "$ROOT/alpine/usbnet.modules"          /etc/mkinitfs/features.d/usbnet.modules
install -m 0644 "$ROOT/alpine/amdgpu.modules"          /etc/mkinitfs/features.d/amdgpu.modules
install -m 0644 "$ROOT/alpine/amdgpu-firmware.files"   /etc/mkinitfs/features.d/amdgpu-firmware.files
install -m 0644 "$ROOT/alpine/nvidia.modules"          /etc/mkinitfs/features.d/nvidia.modules
install -m 0644 "$ROOT/alpine/nvidia-firmware.files"   /etc/mkinitfs/features.d/nvidia-firmware.files

# Install PlayOS custom init scripts so genapkovl-playos.sh can bundle them
# into the apkovl overlay.  These replace or supplement the Alpine-packaged
# init scripts with PlayOS-specific behaviour.
install -m 0755 "$ROOT/alpine/init.d/networkmanager"  /etc/init.d/networkmanager

# Apply PlayOS patches to the Alpine aports scripts.
# This replaces the old fragile sed injections with a version-pinned
# .patch file.  If the patch doesn't apply cleanly, the build fails
# immediately with a clear error telling the maintainer to regenerate.
APORTS_BRANCH="${APORTS_BRANCH}" PLAYOS_ROOT="${PLAYOS_ROOT:-$ROOT}" \
    bash "$ROOT/scripts/apply-aports-patches.sh" "$APORTS"

# Ensure GPU firmware is installed so mkinitfs can bundle it into the
# initramfs (otherwise GPU probe fails before the apkovl is extracted).
apk add --no-cache --no-progress linux-firmware-amdgpu linux-firmware-nvidia linux-firmware-intel 2>&1 | tail -1

# Build and install the hid-asus-ally out-of-tree kernel module (ROG Ally
# controller HID driver).  Phase 3 runs in a separate nspawn session from
# Phase 1, so the module must be rebuilt here.  We copy the .ko directly
# into the running system's module tree so mkinitfs finds it during the
# ISO modloop and initramfs build (same approach as build-disk-image-alpine.sh).
PLAYOS_ROOT="$ROOT" bash "$ROOT/scripts/build-hid-asus-ally.sh"
HID_KO="/var/tmp/playos-build/hid-asus-ally/hid-asus-ally.ko"
KERNEL_VER=$(ls /lib/modules/ | head -1)
if [ -f "$HID_KO" ] && [ -n "$KERNEL_VER" ]; then
    MOD_DEST="/lib/modules/$KERNEL_VER/kernel/drivers/hid"
    mkdir -p "$MOD_DEST"
    cp "$HID_KO" "$MOD_DEST/hid-asus-ally.ko"
    depmod "$KERNEL_VER"
    _log_success "hid-asus-ally.ko installed for ISO modloop/initramfs inclusion"
else
    _log_warn "hid-asus-ally.ko not found — skipping (non-fatal)"
fi

# Create a non-root build user for abuild-keygen (Alpine-native requirement).
if ! id build >/dev/null 2>&1; then
    adduser -D build
    addgroup build abuild
fi

if ! find /home/build/.abuild -maxdepth 1 -name '*.rsa' -print -quit 2>/dev/null | grep -q .; then
    su -s /bin/sh -c "abuild-keygen -a -n" build
fi

# Copy the generated key to /etc/apk/keys so mkimage finds it.
mkdir -p /etc/apk/keys
cp /home/build/.abuild/*.rsa.pub /etc/apk/keys/ 2>/dev/null || true

# Alpine mkimage.sh uses sudo internally; running as root in nspawn so
# set SUDO to empty (skip sudo) and ensure abuild keys are in place.
cd "$APORTS"
export SUDO=
mkdir -p "$HOME/.abuild"
cp /home/build/.abuild/*.rsa /home/build/.abuild/*.rsa.pub "$HOME/.abuild/" 2>/dev/null || true
cp /home/build/.abuild/abuild.conf "$HOME/.abuild/" 2>/dev/null || true
# Ensure PACKAGER_PRIVKEY is set for abuild-sign (used in APKINDEX signing)
if [ -z "${PACKAGER_PRIVKEY:-}" ] && [ -f "$HOME/.abuild/abuild.conf" ]; then
    . "$HOME/.abuild/abuild.conf"
fi

# Clean the build section cache so the initramfs is rebuilt with our
# signing key included.  Without this, stale cached sections (kernel,
# apks) skip rebuild and the initramfs lacks the key trusted to verify
# the signed APKINDEX.
rm -rf "$WORK"/*

sh scripts/mkimage.sh     --tag "$TAG"     --outdir "$OUT"     --workdir "$WORK"     --arch "$ARCH"     --hostkeys     --repository "https://dl-cdn.alpinelinux.org/alpine/$TAG/main"     --repository "https://dl-cdn.alpinelinux.org/alpine/$TAG/community"     --profile playos

echo "PlayOS Alpine image written to $OUT"

# ── Rebuild ISO from the backup DESTDIR (workaround for xorriso corruption
#     inside nspawn's mkimage.sh) and add the disk image at the same time ──
ISO=$(find "$OUT" -maxdepth 1 -name 'alpine-playos-*.iso' -print 2>/dev/null | head -1)
DISK_IMAGE=$(find "$ROOT/out" -maxdepth 1 -name 'playos-gpt-*.img.zst' -print 2>/dev/null | head -1)
STAGING="/var/tmp/playos-destdir-backup"

if [ ! -d "$STAGING" ]; then
    echo "ERROR: DESTDIR backup not found at $STAGING — patch application may have failed" >&2
    exit 1
fi

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "ERROR: mkimage.sh did not produce an ISO" >&2
    exit 1
fi

_log_info "Using backup DESTDIR: $(du -sh "$STAGING" | cut -f1)"

# Verify the apkovl is valid gzip in backup DESTDIR
APKOVL=$(find "$STAGING" -maxdepth 1 -name '*.apkovl.tar.gz' -print 2>/dev/null | head -1)
if [ -n "$APKOVL" ] && gzip -t "$APKOVL" 2>/dev/null; then
    _log_success "apkovl in DESTDIR is valid gzip ($(du -h "$APKOVL" | cut -f1))"
else
    _log_error "apkovl in DESTDIR is missing or invalid"
fi

# Add disk image to staging
if [ -n "$DISK_IMAGE" ] && [ -f "$DISK_IMAGE" ]; then
    _log_info "Adding disk image to staging: $(basename "$DISK_IMAGE")"
    cp "$DISK_IMAGE" "$STAGING/"
fi

# Determine volid from the original ISO
VOLID=$(xorriso -indev "$ISO" -print_info 2>/dev/null | grep 'Volume id' | sed "s/.*'\(.*\)'/\1/" || echo "alpine-playos-x86_64")
VOLID=${VOLID:-alpine-playos-x86_64}

_log_step "Rebuilding ISO from DESTDIR ($VOLID)..."
NEW_ISO="${ISO%.iso}-fixed.iso"

# Build xorrisofs args (replicating Alpine's create_image_iso logic)
ISOLINUX=""
EFIBOOT=""
if [ -f "$STAGING/boot/syslinux/isolinux.bin" ]; then
    ISOLINUX="-isohybrid-mbr $STAGING/boot/syslinux/isohdpfx.bin -eltorito-boot boot/syslinux/isolinux.bin -eltorito-catalog boot/syslinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table"
fi
if [ -d "$STAGING/efi" ] && [ -f "$STAGING/boot/grub/efi.img" ]; then
    if [ -n "$ISOLINUX" ]; then
        EFIBOOT="-eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat"
    else
        EFIBOOT="-e boot/grub/efi.img -no-emul-boot"
    fi
fi

xorrisofs \
    -quiet \
    -output "$NEW_ISO" \
    -full-iso9660-filenames \
    -joliet \
    -rational-rock \
    -sysid LINUX \
    -volid "$VOLID" \
    $ISOLINUX \
    $EFIBOOT \
    "$STAGING/"

# Verify the apkovl in the new ISO
_log_step "Verifying new ISO..."
APKOVL_NAME=$(basename "$APKOVL" 2>/dev/null || echo "playos.apkovl.tar.gz")
TMP_MOUNT="/var/tmp/playos-iso-verify"
mkdir -p "$TMP_MOUNT"
mount -o loop,ro "$NEW_ISO" "$TMP_MOUNT" 2>/dev/null || true
if [ -f "$TMP_MOUNT/$APKOVL_NAME" ]; then
    ISO_SIZE=$(stat -c%s "$TMP_MOUNT/$APKOVL_NAME" 2>/dev/null)
    if gzip -t "$TMP_MOUNT/$APKOVL_NAME" 2>/dev/null; then
        _log_success "apkovl on new ISO is valid gzip ($(numfmt --to=iec $ISO_SIZE))"
    else
        _log_error "apkovl on new ISO is STILL corrupted"
    fi
fi
umount "$TMP_MOUNT" 2>/dev/null || true

# Replace original with fixed
rm -f "$ISO"
mv "$NEW_ISO" "$ISO"
_log_success "Final ISO: $(basename "$ISO") ($(du -h "$ISO" | cut -f1))"

# Cleanup
rm -rf "$STAGING"
