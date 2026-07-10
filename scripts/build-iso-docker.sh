#!/usr/bin/env bash
set -euo pipefail

ROOT="/workspace"
PROFILE="$ROOT/archiso/profiles/playos"
OUT="$ROOT/out"
WORK="/var/tmp/playos-archiso-work"
TMP_PROFILE="/tmp/playos-profile"

if [ ! -d "$PROFILE" ]; then
  echo "Missing archiso profile: $PROFILE"
  echo "Run scripts/init-archiso-profile.sh first."
  exit 1
fi

# ── Copy profile to Linux-native tmpfs (symlinks don't work on Windows mounts) ─

echo "==> Copying profile to Linux-native filesystem"
rm -rf "$TMP_PROFILE"
cp -a "$PROFILE" "$TMP_PROFILE"
AIROOTFS="$TMP_PROFILE/airootfs"

# ── Create systemd symlinks ───────────────────────────────────────────────

echo "==> Setting up systemd symlinks"

mkdir -p "$AIROOTFS/etc/systemd/system"

# Default target: playos-visual.target
ln -sf /etc/systemd/system/playos-visual.target \
  "$AIROOTFS/etc/systemd/system/default.target"

# Enable compositor + seatd in the visual target
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

# ── Build ISO from the tmp profile ────────────────────────────────────────

mkdir -p "$OUT"
rm -rf "$WORK"

echo "==> Building PlayOS ISO (non-interactive)..."
yes '' | mkarchiso -v \
  -w "$WORK" \
  -o "$OUT" \
  "$TMP_PROFILE"

echo "==> Cleaning up"
rm -rf "$TMP_PROFILE"
