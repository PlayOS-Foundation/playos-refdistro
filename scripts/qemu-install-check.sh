#!/usr/bin/env bash
# qemu-install-check.sh — Headless runtime-install check (Sprint 13.7 T7)
#
# Boots the QEMU dev image with playos.install.auto (the same runtime
# installer handoff as the Settings action), attaches a consolidated USB
# image (payload on playos-a) as a second virtio disk (vdb; the QEMU dev
# kernel has no USB controller), and a blank target disk as vda. Verifies:
#   1. init reaches the live shell path
#   2. the auto-install token triggers the runtime handoff
#   3. the installer spawns and completes (exit -> reboot)
#   4. the target disk now carries the installed ESP + playos-a + data layout
#
# Usage:
#   bash scripts/qemu-install-check.sh [--image PATH] [--timeout SECONDS] [--keep]
#
# Environment:
#   QEMU_OUTPUT — Buildroot output for the QEMU dev target (default output/qemu)
#   OVMF_CODE / OVMF_VARS — OVMF firmware paths

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ───────────────────────────────────────────────
IMAGE=""
TIMEOUT=180
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            IMAGE="${2:-}"
            shift 2
            ;;
        --image=*)
            IMAGE="${1#*=}"
            shift
            ;;
        --timeout)
            TIMEOUT="${2:-180}"
            shift 2
            ;;
        --timeout=*)
            TIMEOUT="${1#*=}"
            shift
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--image PATH] [--timeout SECONDS] [--keep]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

QEMU_OUTPUT="${QEMU_OUTPUT:-$SCRIPT_DIR/../output/qemu}"
if [[ -z "$IMAGE" ]]; then
    IMAGE="$SCRIPT_DIR/../output/ally/images/playos-ally-dev-usb.img"
fi
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

echo "==> PlayOS QEMU runtime-install check"
echo "    USB image:  $IMAGE"
echo "    QEMU output: $QEMU_OUTPUT"

if [[ ! -f "$IMAGE" ]]; then
    echo "ERROR: USB image not found: $IMAGE" >&2
    exit 1
fi

# ── Find boot artifacts ────────────────────────────────────────────
BZIMAGE=""
INITRAMFS=""
for candidate in "$QEMU_OUTPUT/images/bzImage" "$QEMU_OUTPUT/build/linux-"*/arch/x86/boot/bzImage; do
    if [[ -f "$candidate" ]]; then BZIMAGE="$candidate"; break; fi
done
for candidate in "$QEMU_OUTPUT/images/rootfs.cpio" "$QEMU_OUTPUT/images/rootfs.initramfs"; do
    if [[ -f "$candidate" ]]; then INITRAMFS="$candidate"; break; fi
done
if [[ -z "$BZIMAGE" || -z "$INITRAMFS" ]]; then
    echo "ERROR: QEMU kernel/initramfs not found. Run 'make qemu-build' first." >&2
    exit 1
fi
echo "    Kernel:     $BZIMAGE"
echo "    Initramfs:  $INITRAMFS"

# ── OVMF firmware ──────────────────────────────────────────────────
if [[ ! -f "$OVMF_CODE" ]]; then
    for candidate in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF.fd; do
        if [[ -f "$candidate" ]]; then OVMF_CODE="$candidate"; break; fi
    done
fi
if [[ ! -f "$OVMF_CODE" ]]; then
    echo "ERROR: OVMF firmware not found. Install the 'ovmf' package." >&2
    exit 1
fi
OVMF_VARS_TMP="$(mktemp)"
if [[ -f "$OVMF_VARS" ]]; then
    cp "$OVMF_VARS" "$OVMF_VARS_TMP"
else
    dd if=/dev/zero of="$OVMF_VARS_TMP" bs=1M count=4 status=none
fi

# ── Create a blank target disk ─────────────────────────────────────
TARGET="$QEMU_OUTPUT/images/install-target.img"
USB_COPY="$QEMU_OUTPUT/images/qemu-install-usb-copy.img"
rm -f "$TARGET" "$USB_COPY"
echo "==> Creating blank target disk: $TARGET"
# The installed layout is ESP + 2x4G A/B slots + misc + data (~8.6G min).
truncate -s 16G "$TARGET"

# ── Writable copy of the USB image (init mounts ESP//data rw) ──────
echo "==> Copying USB image (sparse): $USB_COPY"
if ! cp --reflink=auto "$IMAGE" "$USB_COPY" 2>/dev/null; then
    cp --sparse=always "$IMAGE" "$USB_COPY"
fi

# ── Boot in QEMU ───────────────────────────────────────────────────
BOOT_LOG="$(mktemp)"
echo "==> Booting with ${TIMEOUT}s timeout (playos.install.auto)..."

timeout "$TIMEOUT" qemu-system-x86_64 \
    -m 1024M \
    -machine q35,accel=kvm:tcg \
    -cpu qemu64 \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_TMP" \
    -kernel "$BZIMAGE" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200n8 playos.install.auto playos.install.auto=1 quiet" \
    -drive if=none,id=target,format=raw,file="$TARGET" \
    -device virtio-blk-pci,drive=target \
    -device qemu-xhci,id=xhci \
    -drive if=none,id=usbimg,format=raw,file="$USB_COPY" \
    -device usb-storage,bus=xhci.0,drive=usbimg \
    -device virtio-gpu-pci \
    -serial stdio \
    -display none \
    -no-reboot \
    > "$BOOT_LOG" 2>&1 || true

set +e
QEMU_EXIT=$?
set -e

echo "==> QEMU exited (code $QEMU_EXIT). Analyzing log: $BOOT_LOG"

# ── Verify handoff log evidence ────────────────────────────────────
FAIL=0
for marker in \
    "auto-install requested" \
    "stopping shell PID" \
    "installer launched" \
    "runtime installer finished" \
    "rebooting"; do
    if grep -q "$marker" "$BOOT_LOG"; then
        echo "  [OK] log marker: $marker"
    else
        echo "  [FAIL] missing log marker: $marker"
        FAIL=1
    fi
done

if grep -q "installer PID .* exited: code=0" "$BOOT_LOG"; then
    echo "  [OK] installer exited cleanly (code=0)"
else
    echo "  [WARN] no clean installer exit code in log"
fi

# ── Verify target disk layout ──────────────────────────────────────
echo "==> Target disk layout:"
sgdisk -p "$TARGET" 2>/dev/null | sed -n '1,12p' || true

ESP_OK=0
PAYLOAD_OK=0
DATA_OK=0
LOOP_DEV=$(sudo losetup --partscan --find --show "$TARGET" 2>/dev/null || true)
if [[ -n "$LOOP_DEV" ]]; then
    sleep 1
    M="$(mktemp -d)"
    # Installed layout: p1 = ESP (BOOTX64.EFI), p2 = raw squashfs rootfs.
    if sudo mount "${LOOP_DEV}p1" "$M" 2>/dev/null; then
        if [[ -f "$M/EFI/BOOT/BOOTX64.EFI" ]]; then
            echo "  [OK] target ESP has EFI/BOOT/BOOTX64.EFI"
            ESP_OK=1
        else
            echo "  [FAIL] target ESP missing EFI/BOOT/BOOTX64.EFI"
        fi
        sudo umount "$M"
    else
        echo "  [FAIL] could not mount target ESP"
    fi
    if sudo mount "${LOOP_DEV}p2" "$M" 2>/dev/null; then
        if [[ -f "$M/init" && -d "$M/usr" && -d "$M/etc" ]]; then
            echo "  [OK] target playos-a is a populated squashfs rootfs"
            PAYLOAD_OK=1
        else
            echo "  [FAIL] target playos-a does not look like a rootfs:"
            ls -la "$M" 2>/dev/null | head -12 || true
        fi
        sudo umount "$M"
    else
        echo "  [FAIL] could not mount target playos-a"
    fi
    if sudo mount "${LOOP_DEV}p5" "$M" 2>/dev/null; then
        if [[ -s "$M/ssh/authorized_keys" ]]; then
            echo "  [OK] target playos-data has dev SSH key seeded"
            DATA_OK=1
        else
            echo "  [FAIL] target playos-data missing ssh/authorized_keys"
        fi
        sudo umount "$M"
    else
        echo "  [FAIL] could not mount target playos-data"
    fi
    rmdir "$M"
    sudo losetup -d "$LOOP_DEV"
else
    echo "  [FAIL] could not attach target disk to loop device"
fi

if [[ "$FAIL" == "0" && "$ESP_OK" == "1" && "$PAYLOAD_OK" == "1" && "$DATA_OK" == "1" ]]; then
    echo ""
    echo "  ✅ QEMU runtime-install check PASSED"
else
    echo ""
    echo "  ❌ QEMU runtime-install check FAILED"
fi

# ── Cleanup ────────────────────────────────────────────────────────
rm -f "$OVMF_VARS_TMP"
if [[ "$KEEP" == "0" ]]; then
    rm -f "$TARGET" "$USB_COPY" "$BOOT_LOG"
else
    echo "==> Kept: $TARGET"
    echo "==> Kept: $USB_COPY"
    echo "==> Kept: $BOOT_LOG"
fi

[[ "$FAIL" == "0" && "$PAYLOAD_OK" == "1" ]]
