#!/usr/bin/env bash
# build-iso-vmware.sh — build the PlayOS ISO on a native Arch Linux host
# (VM, bare metal, or any system with archiso installed).
# Run scripts/setup-arch-build-host.sh first on a fresh system.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="$ROOT/archiso/profiles/playos"
OUT="$ROOT/out"
WORK="/tmp/playos-archiso-work"
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
mkdir -p "$AIROOTFS/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/playos-firstboot.service \
  "$AIROOTFS/etc/systemd/system/sysinit.target.wants/playos-firstboot.service"

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

# ── Build ISO ─────────────────────────────────────────────────────────────

mkdir -p "$OUT"
rm -rf "$WORK"

echo "==> Building PlayOS ISO..."
mkarchiso -v \
  -w "$WORK" \
  -o "$OUT" \
  "$PROFILE"

echo ""
echo "==> Done:"
ls -lh "$OUT"/*.iso
