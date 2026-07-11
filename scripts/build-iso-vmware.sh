#!/usr/bin/env bash
# build-iso-vmware.sh — build the PlayOS ISO on a native Arch Linux host
# (VM, bare metal, or any system with archiso installed).
# Run scripts/setup-arch-build-host.sh first on a fresh system.
set -euo pipefail
export TMPDIR=/var/tmp   # ensure cmake/ninja/mkarchiso never use /tmp

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="$ROOT/archiso/profiles/playos"
OUT="$ROOT/out"
WORK="/var/tmp/playos-archiso-work"
AIROOTFS="$PROFILE/airootfs"

if [ ! -d "$PROFILE" ]; then
  echo "Missing archiso profile: $PROFILE"
  echo "Run scripts/init-archiso-profile.sh first."
  exit 1
fi

# ── Create systemd symlinks ───────────────────────────────────────────────

echo "==> Setting up systemd symlinks"

mkdir -p "$AIROOTFS/etc/systemd/system"

# Default target: playos-visual.target
ln -sf /etc/systemd/system/playos-visual.target \
  "$AIROOTFS/etc/systemd/system/default.target"

# Enable compositor + seatd
mkdir -p "$AIROOTFS/etc/systemd/system/playos-visual.target.wants"
ln -sf /etc/systemd/system/playos-compositor.service \
  "$AIROOTFS/etc/systemd/system/playos-visual.target.wants/playos-compositor.service"
ln -sf /usr/lib/systemd/system/seatd.service \
  "$AIROOTFS/etc/systemd/system/playos-visual.target.wants/seatd.service"

# Enable bootstrap service (network + sshd + locale)
mkdir -p "$AIROOTFS/etc/systemd/system/playos-visual.target.wants"
ln -sf /etc/systemd/system/playos-firstboot.service \
  "$AIROOTFS/etc/systemd/system/playos-visual.target.wants/playos-firstboot.service"

# Enable async services
mkdir -p "$AIROOTFS/etc/systemd/system/playos-async.target.wants"
for svc in playos-audio.service playos-network.service playos-bluetooth.service playos-library.service playos-update.service; do
  ln -sf "/etc/systemd/system/$svc" \
    "$AIROOTFS/etc/systemd/system/playos-async.target.wants/$svc"
done

# Fix script permissions
find "$AIROOTFS/usr/bin" -type f -exec chmod +x {} \; 2>/dev/null || true
find "$AIROOTFS/usr/lib/playos" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "==> Symlinks and permissions set up"

# ── Build PlayOS binaries from source ────────────────────────────────────

"$SCRIPT_DIR/build-playos-binaries.sh" "$AIROOTFS"

# ── Build ISO ─────────────────────────────────────────────────────────────

mkdir -p "$OUT"
rm -rf "$WORK"

echo "==> Building PlayOS ISO..."
# Use /var/tmp for mkarchiso temp files; avoids tmpfs size limits on /tmp
export TMPDIR=/var/tmp
mkarchiso -v \
  -w "$WORK" \
  -o "$OUT" \
  "$PROFILE"

echo ""
echo "==> Done:"
ls -lh "$OUT"/*.iso

# ── Refresh PXE netboot files (if dnsmasq is configured) ──────────────────
if [ -d /srv/playos-pxe ] && command -v mount > /dev/null; then
    echo "==> Refreshing PXE netboot files..."
    ISO_FILE=$(ls -t "$OUT"/*.iso 2>/dev/null | head -1)
    if [ -n "$ISO_FILE" ]; then
        mkdir -p /mnt/iso /srv/playos-pxe/arch/x86_64
        mount -o loop "$ISO_FILE" /mnt/iso 2>/dev/null || true
        cp /mnt/iso/arch/boot/x86_64/vmlinuz-linux /srv/playos-pxe/ 2>/dev/null || true
        cp /mnt/iso/arch/boot/x86_64/initramfs-linux.img /srv/playos-pxe/ 2>/dev/null || true
        cp /mnt/iso/arch/x86_64/airootfs.erofs /srv/playos-pxe/arch/x86_64/ 2>/dev/null || true
        umount /mnt/iso 2>/dev/null || true
        echo "    PXE boot files updated ($(date +%H:%M:%S))"
    fi
fi
