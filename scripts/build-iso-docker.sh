#!/usr/bin/env bash
set -euo pipefail

ROOT="/workspace"
PROFILE="$ROOT/archiso/profiles/playos"
OUT="$ROOT/out"
WORK="/tmp/playos-archiso-work"
AIROOTFS="$PROFILE/airootfs"

if [ ! -d "$PROFILE" ]; then
  echo "Missing archiso profile: $PROFILE"
  echo "Run scripts/init-archiso-profile.sh first."
  exit 1
fi

# ── Create systemd symlinks (must be done on Linux; cannot be done on Windows) ─

echo "==> Setting up systemd symlinks"

# Default target: playos-visual.target
mkdir -p "$AIROOTFS/etc/systemd/system"
ln -sf /etc/systemd/system/playos-visual.target \
  "$AIROOTFS/etc/systemd/system/default.target"

# Enable compositor + seatd in the visual target
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

# Fix script permissions (lost on Windows)
find "$AIROOTFS/usr/bin" -type f -exec chmod +x {} \; 2>/dev/null || true
find "$AIROOTFS/usr/lib/playos" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "==> Symlinks and permissions set up"

# ── Build ISO ─

mkdir -p "$OUT"
rm -rf "$WORK"

mkarchiso -v \
  -w "$WORK" \
  -o "$OUT" \
  "$PROFILE"
