#!/usr/bin/env bash
# qemu-recovery-check.sh — S14 F3: recovery must render with no accelerated GPU.
#
# Boots the QEMU dev image with QEMU's cirrus VGA, for which this kernel has no
# driver, so the only DRM device in the guest is the kernel's SimplEDRM wrapper
# around the OVMF framebuffer. That is the "graphics is what broke" case: no
# amdgpu, no EGL/GL, no GBM. The guest is asked for the recovery UI on the kernel
# cmdline (playos.recovery); this check then reads the emulated framebuffer over
# the QEMU monitor and asserts that the menu actually made it to the screen.
#
# Usage: scripts/qemu-recovery-check.sh [output-dir]
#
# Evidence left in the output dir: recovery.ppm (+ .png), serial.log, and the
# guest's own logs from the data disk when the caller can mount it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QEMU_OUT="$REPO_DIR/output/qemu"
OUT_DIR="${1:-$REPO_DIR/output/f3-recovery-check}"

BZIMAGE="$QEMU_OUT/images/bzImage"
INITRAMFS="$QEMU_OUT/images/rootfs.cpio"
DATA_DISK="$QEMU_OUT/images/data.img"
TIMEOUT="${F3_TIMEOUT:-90}"
SETTLE="${F3_SETTLE:-8}"
# F3_APPEND lets the caller exercise the GL-free recovery client: with
# "playos.noshell=1" the shell fails by design, so init falls back to
# playos-recovery — the path a machine with a broken GPU stack takes.
EXTRA_APPEND="${F3_APPEND:-}"

for f in "$BZIMAGE" "$INITRAMFS" "$DATA_DISK"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing $f — build the QEMU image first (make qemu-build)" >&2
        exit 1
    fi
done

# ── OVMF firmware (same lookup order as qemu-boot-check.sh) ────────────────
OVMF_CODE="${OVMF_CODE:-}"
if [ -z "$OVMF_CODE" ]; then
    for c in /usr/share/OVMF/OVMF_CODE_4M.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/edk2-ovmf/OVMF_CODE.fd \
             /usr/share/qemu/OVMF.fd; do
        [ -f "$c" ] && { OVMF_CODE="$c"; break; }
    done
fi
if [ -z "$OVMF_CODE" ]; then
    echo "ERROR: OVMF firmware not found (install the 'ovmf' package)" >&2
    exit 1
fi
OVMF_VARS_SRC="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
if [ ! -f "$OVMF_VARS_SRC" ]; then
    OVMF_VARS_SRC="$(dirname "$OVMF_CODE")/OVMF_VARS_4M.fd"
fi
if [ ! -f "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF vars template not found (set OVMF_VARS=…)" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
MON_SOCK="$OUT_DIR/monitor.sock"
SERIAL="$OUT_DIR/serial.log"
PPM="$OUT_DIR/recovery.ppm"
rm -f "$MON_SOCK" "$SERIAL" "$PPM"
OVMF_VARS_TMP="$(mktemp)"
cp "$OVMF_VARS_SRC" "$OVMF_VARS_TMP"

cleanup() {
    [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null || true
    rm -f "$OVMF_VARS_TMP" "$MON_SOCK"
}
trap cleanup EXIT

echo "==> booting with no GPU driver (QEMU cirrus VGA, kernel has no cirrus DRM)"
timeout "$TIMEOUT" qemu-system-x86_64 \
    -m 1024M \
    -machine q35,accel=kvm:tcg \
    -cpu qemu64 \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_TMP" \
    -kernel "$BZIMAGE" \
    -initrd "$INITRAMFS" \
    -drive if=none,id=data,format=raw,file="$DATA_DISK" \
    -device virtio-blk-pci,drive=data \
    -append "console=ttyS0,115200n8 quiet playos.recovery $EXTRA_APPEND" \
    -serial "file:$SERIAL" \
    -vga cirrus \
    -display none \
    -monitor "unix:$MON_SOCK,server,nowait" \
    > /dev/null 2>&1 &
QPID=$!

# ── Wait for the guest to reach the shell ─────────────────────────────────
reached=0
for _ in $(seq 1 "$TIMEOUT"); do
    if grep -qa "system ready" "$SERIAL" 2>/dev/null; then
        reached=1
        break
    fi
    kill -0 "$QPID" 2>/dev/null || break
    sleep 1
done
if [ "$reached" -ne 1 ]; then
    echo "FAIL: guest did not reach the shell (see $SERIAL)" >&2
    exit 1
fi

sleep "$SETTLE"   # let the recovery UI present a frame

# ── Grab the framebuffer through the QEMU monitor ─────────────────────────
python3 - "$MON_SOCK" "$PPM" <<'PY'
import socket, sys, time
sock_path, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(50):
    try:
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.2)
else:
    sys.exit("could not connect to the QEMU monitor")
time.sleep(0.5)
s.recv(65536)
s.sendall(("screendump %s\n" % out).encode())
time.sleep(2.0)
s.close()
PY

# ── Assert the menu is on screen ──────────────────────────────────────────
python3 - "$PPM" <<'PY'
import sys
path = sys.argv[1]
try:
    data = open(path, 'rb').read()
except OSError as e:
    sys.exit("FAIL: no screendump (%s)" % e)

# P6 PPM: magic, width, height, maxval, then RGB triples
parts = data.split(b'\n', 3)
if len(parts) < 4 or parts[0].strip() != b'P6':
    sys.exit("FAIL: %s is not a P6 PPM" % path)
w, h = (int(x) for x in parts[1].split())
px = parts[3]
total = w * h
nonblack = 0
colours = {}
for i in range(0, min(len(px), total * 3), 3):
    r, g, b = px[i], px[i+1], px[i+2]
    if r or g or b:
        nonblack += 1
        colours[(r // 32, g // 32, b // 32)] = colours.get((r // 32, g // 32, b // 32), 0) + 1

ratio = nonblack / total if total else 0
print("framebuffer      : %dx%d" % (w, h))
print("non-black pixels : %d/%d (%.2f%%)" % (nonblack, total, ratio * 100))
print("distinct colours : %d" % len(colours))
if ratio < 0.005:
    sys.exit("FAIL: framebuffer is (nearly) blank — the recovery menu did not render")
print("PASS: recovery UI rendered with software rendering (no GPU driver)")
PY

echo "==> evidence: $PPM, $SERIAL"
echo "==> guest renderer choice (needs root to read the data disk):"
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    MNT="$(mktemp -d)"
    # noload: the disk is left dirty by the killed QEMU, which would otherwise
    # refuse a read-only journal replay.
    if sudo mount -o ro,noload,loop "$DATA_DISK" "$MNT" 2>/dev/null; then
        echo "    renderer/device:"
        # tr -d '\0': the append-only log is sparse, so raw greps emit NUL runs
        sudo tr -d '\0' < "$MNT/log/compositor-stderr.log" 2>/dev/null \
            | grep -aE "DRM device|software rendering|renderer forced|SimplEDRM" \
            | tail -4 | sed 's/^/      /' || true
        echo "    recovery client:"
        sudo tr -d '\0' < "$MNT/log/init.log" 2>/dev/null \
            | grep -aE "recovery client launched|GL-free recovery client" \
            | tail -3 | sed 's/^/      /' || true
        echo "    init:"
        sudo tr -d '\0' < "$MNT/log/init.log" 2>/dev/null \
            | grep -aE "recovery requested|cmdline:" | tail -3 | sed 's/^/      /' || true
        sudo umount "$MNT"
    else
        echo "    (could not mount $DATA_DISK)"
    fi
    rmdir "$MNT" 2>/dev/null || true
else
    echo "    (skipped: sudo without a password is not available)"
fi
