#!/usr/bin/env bash
# test-disk-image-qemu.sh — Boot a PlayOS disk image in QEMU with OVMF.
#
# Validates the full boot chain: firmware → systemd-boot → kernel → init →
# OpenRC services → compositor startup.
#
# Usage:  bash scripts/test-disk-image-qemu.sh [path-to.img.zst]
#         If no path given, picks the latest .img.zst from out/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QEMU_DIR="$ROOT/.build/qemu"
OUT="$ROOT/out"
TIMEOUT_SEC=150

# ── Locate disk image ────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    ZST="$(readlink -f "$1")"
else
    ZST="$(find "$OUT" -maxdepth 1 -type f -name '*.img.zst' \
        -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
fi

if [[ -z "${ZST:-}" || ! -f "$ZST" ]]; then
    echo "error: no disk image found; pass a .img.zst path or build it first" >&2
    exit 1
fi

echo "==> Disk image: $ZST"

# ── Verify checksum if available ─────────────────────────────────────────────
if [[ -f "${ZST}.sha256" ]]; then
    echo "==> Verifying checksum"
    ZST_DIR="$(dirname "$ZST")"
    ZST_NAME="$(basename "$ZST")"
    if ! (cd "$ZST_DIR" && sha256sum -c "${ZST_NAME}.sha256" --quiet 2>/dev/null); then
        echo "error: checksum mismatch for $ZST" >&2
        exit 1
    fi
    echo "    Checksum OK"
fi

# ── Decompress ───────────────────────────────────────────────────────────────
RAW="$ROOT/.build/qemu/playos-test-boot.img"
mkdir -p "$(dirname "$RAW")"
echo "==> Decompressing to $RAW"
zstd -d -f -o "$RAW" "$ZST"
RAW_SIZE=$(du -h "$RAW" | cut -f1)
echo "    Size: $RAW_SIZE"

cleanup_raw() { rm -f "$RAW"; }
trap cleanup_raw EXIT

# ── Patch boot entry for QEMU/TCG compatibility ──────────────────────────────
# Ensure usbdelay=30 (extends nlplug-findfs timeout for slow TCG block detection)
# and console=ttyS0 is present for boot marker detection on serial.
echo "==> Patching boot entry for QEMU compatibility"
LOOP_PATCH=$(sudo losetup --find --show -P "$RAW")
MNT_PATCH=$(mktemp -d)
sudo mount "${LOOP_PATCH}p1" "$MNT_PATCH"
CONF="$MNT_PATCH/loader/entries/playos.conf"
if ! grep -q 'usbdelay=' "$CONF" 2>/dev/null; then
    sudo sed -i 's/ quiet/ usbdelay=30 quiet/' "$CONF"
fi
if ! grep -q 'console=ttyS0' "$CONF" 2>/dev/null; then
    sudo sed -i 's/console=tty0 /console=tty0 console=ttyS0 /' "$CONF"
fi
echo "    Boot entry: $(grep '^options' "$CONF")"
sudo umount "$MNT_PATCH"
rmdir "$MNT_PATCH"
sudo losetup -d "$LOOP_PATCH"

# ── Locate OVMF firmware ─────────────────────────────────────────────────────
CODE=""
VARS=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [[ -f "$c" ]] && { CODE="$c"; break; }
done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -f "$v" ]] && { VARS="$v"; break; }
done

if [[ -z "$CODE" ]]; then
    echo "error: OVMF firmware not found" >&2
    exit 1
fi

mkdir -p "$QEMU_DIR"

# ── Acceleration ─────────────────────────────────────────────────────────────
ACCEL=(-machine q35,accel=tcg -cpu max)
[[ -r /dev/kvm && -w /dev/kvm ]] && ACCEL=(-machine q35,accel=kvm -cpu host)

# ── Firmware (UEFI) ──────────────────────────────────────────────────────────
FIRMWARE=(-bios "$CODE")
if [[ -n "$VARS" ]]; then
    cp "$VARS" "$QEMU_DIR/OVMF_VARS.fd"
    FIRMWARE=(
        -drive "if=pflash,format=raw,readonly=on,file=$CODE"
        -drive "if=pflash,format=raw,file=$QEMU_DIR/OVMF_VARS.fd"
    )
fi

# ── Boot markers (ordered severity: SUCCESS > WARNING > FAILURE) ─────────────
# Each line is: regex | label | severity
# OpenRC output format: "* Starting ServiceName ... [ ok ]"
MARKERS=(
    "Starting PlayOS compositor.*\[ ok \]|compositor started|SUCCESS"
    "Starting seatd.*\[ ok \]|seatd started|SUCCESS"
    "Starting System Message Bus.*\[ ok \]|dbus started|SUCCESS"
    "Starting sshd.*\[ ok \]|SSH server started|SUCCESS"
    "Running PlayOS first-boot|firstboot service|SUCCESS"
    "Starting busybox syslog.*\[ ok \]|syslog started|SUCCESS"
    "Remounting root filesystem.*\[ ok \]|root remounted rw|SUCCESS"
    "Kernel panic|KERNEL PANIC|FAILURE"
    "Unable to mount root|root mount failure|FAILURE"
    "Mounting root failed|root mount failure|FAILURE"
    "No bootable device|no boot device|FAILURE"
    "VFS: Cannot open root|VFS root failure|FAILURE"
)

# ── Boot ─────────────────────────────────────────────────────────────────────
echo "==> Booting disk image (timeout: ${TIMEOUT_SEC}s)"
echo "    QEMU console: Ctrl-A X exits"

SERIAL_LOG="$QEMU_DIR/qemu-boot.log"
: > "$SERIAL_LOG"

qemu-system-x86_64 \
    "${ACCEL[@]}" \
    "${FIRMWARE[@]}" \
    -m 2048 \
    -smp 2 \
    -device virtio-vga \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -nic user,model=virtio-net-pci \
    -drive "file=$RAW,format=raw,if=none,id=disk0" \
    -device ahci,id=ahci \
    -device ide-hd,drive=disk0,bus=ahci.0 \
    -boot order=c \
    -no-reboot &
QEMU_PID=$!

# ── Monitor serial output for boot markers ───────────────────────────────────
echo "==> Monitoring boot progress..."
FOUND_SUCCESS=""
FOUND_FAILURE=""
LAST_CHECK=0

for ((t=0; t<TIMEOUT_SEC; t++)); do
    sleep 1
    [[ -f "$SERIAL_LOG" ]] || continue

    for marker in "${MARKERS[@]}"; do
        IFS='|' read -r pattern label severity <<< "$marker"
        if grep -q "$pattern" "$SERIAL_LOG" 2>/dev/null; then
            case "$severity" in
                SUCCESS)
                    if [[ "$FOUND_SUCCESS" != *"$label"* ]]; then
                        echo "    ✓ $label"
                        FOUND_SUCCESS="${FOUND_SUCCESS}${label};"
                    fi
                    ;;
                FAILURE)
                    if [[ "$FOUND_FAILURE" != *"$label"* ]]; then
                        echo "    ✗ $label"
                        FOUND_FAILURE="${FOUND_FAILURE}${label};"
                    fi
                    ;;
            esac
        fi
    done

    # Check if QEMU died early
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "    QEMU exited after ${t}s"
        break
    fi
done

# ── Kill QEMU ────────────────────────────────────────────────────────────────
if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "==> Timeout — stopping QEMU"
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
fi

# ── Report ───────────────────────────────────────────────────────────────────
echo
echo "============================================================================"
echo "Boot test results for: $(basename "$ZST")"
echo "============================================================================"

if [[ -n "$FOUND_FAILURE" ]]; then
    echo "FAIL — boot errors detected:"
    IFS=';' read -ra FAILS <<< "$FOUND_FAILURE"
    for f in "${FAILS[@]}"; do
        [[ -n "$f" ]] && echo "  ✗ $f"
    done
    echo
    echo "Serial log (last 40 lines):"
    tail -40 "$SERIAL_LOG"
    echo
    exit 1
fi

if [[ -n "$FOUND_SUCCESS" ]]; then
    echo "PASS — boot chain validated:"
    IFS=';' read -ra OKS <<< "$FOUND_SUCCESS"
    for o in "${OKS[@]}"; do
        [[ -n "$o" ]] && echo "  ✓ $o"
    done
else
    echo "INCONCLUSIVE — no boot markers detected"
    echo
    echo "Serial log (all):"
    cat "$SERIAL_LOG"
    echo
    exit 2
fi

echo
echo "Serial log ($(wc -l < "$SERIAL_LOG") lines): $SERIAL_LOG"
echo "============================================================================"
exit 0
