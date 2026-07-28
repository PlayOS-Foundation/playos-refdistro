#!/usr/bin/env bash
set -euo pipefail

ROOT="${PLAYOS_ROOT:-/workspace}"
OUT="$ROOT/out"
WORK="${PLAYOS_WORKDIR:-/var/tmp/playos-mkimage}"
APORTS="${PLAYOS_APORTS_DIR:-/var/cache/playos-aports}"
APORTS_BRANCH="${PLAYOS_APORTS_BRANCH:-3.24-stable}"
TAG="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"

if [[ "$TAG" == "edge" ]]; then
    echo "error: unpinned Alpine edge builds are forbidden" >&2
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

# apk-tools 3.0.6+: --no-chown conflicts with root (implies usermode).
# Remove it — we run as root in nspawn, so chown is fine.
sed -i 's/--no-chown//g' "$APORTS/scripts/mkimage.sh"

# Replace cp -Lrs (symlinks) with cp -rL (hard copies) to avoid xorriso
# symlink-following bugs that corrupt the apkovl on the ISO.
sed -i 's/cp -Lrs/cp -rL/' "$APORTS/scripts/mkimage.sh"

# Intercept the DESTDIR before xorrisofs corrupts the apkovl.
# Insert a line before the xorrisofs call in create_image_iso that
# copies DESTDIR to a safe location for our own ISO rebuild.
sed -i '/^[[:space:]]*xorrisofs \\/i\cp -a "${DESTDIR}" /var/tmp/playos-destdir-backup' "$APORTS/scripts/mkimg.base.sh"

# Verify the sed injection succeeded — if Alpine upstream changed the
# formatting of mkimg.base.sh, this will fail early with a clear error.
if ! grep -q 'cp -a.*DESTDIR.*playos-destdir-backup' "$APORTS/scripts/mkimg.base.sh"; then
    echo "ERROR: Failed to inject DESTDIR backup into mkimg.base.sh" >&2
    echo "The xorrisofs line pattern may have changed upstream. Check:" >&2
    echo "  grep -n xorrisofs $APORTS/scripts/mkimg.base.sh" >&2
    exit 1
fi

# Remove sd-mod,usb-storage and quiet from default initfs_cmdline.
# sd-mod/usb-storage probe hardware that may hang during netboot;
# quiet suppresses messages needed for debugging.
sed -i 's/initfs_cmdline="modules=loop,squashfs,sd-mod,usb-storage quiet"/initfs_cmdline="modules=loop,squashfs"/' "$APORTS/scripts/mkimg.base.sh"

# Ensure GPU firmware is installed so mkinitfs can bundle it into the
# initramfs (otherwise GPU probe fails before the apkovl is extracted).
apk add --no-cache linux-firmware-amdgpu linux-firmware-nvidia linux-firmware-intel 2>&1 | tail -1

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
    echo "ERROR: DESTDIR backup not found at $STAGING — sed injection may have failed" >&2
    exit 1
fi

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "ERROR: mkimage.sh did not produce an ISO" >&2
    exit 1
fi

echo "==> Using backup DESTDIR: $(du -sh "$STAGING" | cut -f1)"

# Verify the apkovl is valid gzip in backup DESTDIR
APKOVL=$(find "$STAGING" -maxdepth 1 -name '*.apkovl.tar.gz' -print 2>/dev/null | head -1)
if [ -n "$APKOVL" ] && gzip -t "$APKOVL" 2>/dev/null; then
    echo "    ✅ apkovl in DESTDIR is valid gzip ($(du -h "$APKOVL" | cut -f1))"
else
    echo "    ❌ apkovl in DESTDIR is missing or invalid"
fi

# Add disk image to staging
if [ -n "$DISK_IMAGE" ] && [ -f "$DISK_IMAGE" ]; then
    echo "==> Adding disk image to staging: $(basename "$DISK_IMAGE")"
    cp "$DISK_IMAGE" "$STAGING/"
fi

# Determine volid from the original ISO
VOLID=$(xorriso -indev "$ISO" -print_info 2>/dev/null | grep 'Volume id' | sed "s/.*'\(.*\)'/\1/" || echo "alpine-playos-x86_64")
VOLID=${VOLID:-alpine-playos-x86_64}

echo "==> Rebuilding ISO from DESTDIR ($VOLID)..."
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
echo "==> Verifying new ISO..."
APKOVL_NAME=$(basename "$APKOVL" 2>/dev/null || echo "playos.apkovl.tar.gz")
TMP_MOUNT="/var/tmp/playos-iso-verify"
mkdir -p "$TMP_MOUNT"
mount -o loop,ro "$NEW_ISO" "$TMP_MOUNT" 2>/dev/null || true
if [ -f "$TMP_MOUNT/$APKOVL_NAME" ]; then
    ISO_SIZE=$(stat -c%s "$TMP_MOUNT/$APKOVL_NAME" 2>/dev/null)
    if gzip -t "$TMP_MOUNT/$APKOVL_NAME" 2>/dev/null; then
        echo "    ✅ apkovl on new ISO is valid gzip ($(numfmt --to=iec $ISO_SIZE))"
    else
        echo "    ❌ apkovl on new ISO is STILL corrupted"
    fi
fi
umount "$TMP_MOUNT" 2>/dev/null || true

# Replace original with fixed
rm -f "$ISO"
mv "$NEW_ISO" "$ISO"
echo "==> Final ISO: $(basename "$ISO") ($(du -h "$ISO" | cut -f1))"

# Cleanup
rm -rf "$STAGING"
