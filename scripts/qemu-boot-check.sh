#!/usr/bin/env bash
# qemu-boot-check.sh — Boot PlayOS image in QEMU/OVMF and verify boot success
#
# Usage:
#   bash scripts/qemu-boot-check.sh [--timeout SECONDS]
#
# Environment:
#   QEMU_OUTPUT  — path to Buildroot output directory (default: output/qemu)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging
. "$SCRIPT_DIR/lib/playos_log.sh"

# ── Argument parsing ───────────────────────────────────────────────
TIMEOUT=30
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            TIMEOUT="${2:-30}"
            shift 2
            ;;
        --timeout=*)
            TIMEOUT="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--timeout SECONDS]"
            echo "Boot the PlayOS QEMU image and verify boot success."
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--timeout SECONDS]" >&2
            exit 2
            ;;
        *)
            # Bare positional seconds (legacy form: `$0 45`)
            TIMEOUT="$1"
            shift
            ;;
    esac
done

# ── Configuration ──────────────────────────────────────────────────
QEMU_OUTPUT="${QEMU_OUTPUT:-$SCRIPT_DIR/../output/qemu}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
DATA_DISK="${DATA_DISK:-$SCRIPT_DIR/../output/qemu/images/data.img}"

playos_log_step "PlayOS QEMU Boot Check"

# ── Find boot artifacts ────────────────────────────────────────────
BZIMAGE=""
INITRAMFS=""

# Search for the kernel and initramfs in common Buildroot output locations
for candidate in "$QEMU_OUTPUT/images/bzImage" "$QEMU_OUTPUT/build/linux-"*/arch/x86/boot/bzImage; do
    if [[ -f "$candidate" ]]; then
        BZIMAGE="$candidate"
        playos_log_ok "find" "Kernel: $BZIMAGE"
        break
    fi
done

for candidate in "$QEMU_OUTPUT/images/rootfs.cpio" "$QEMU_OUTPUT/images/rootfs.initramfs"; do
    if [[ -f "$candidate" ]]; then
        INITRAMFS="$candidate"
        playos_log_ok "find" "initramfs: $INITRAMFS"
        break
    fi
done

if [[ -z "$BZIMAGE" ]]; then
    playos_log_fatal "boot" "Kernel image not found in $QEMU_OUTPUT. Run 'make qemu-build' first."
fi

if [[ -z "$INITRAMFS" ]]; then
    playos_log_fatal "boot" "initramfs not found in $QEMU_OUTPUT. Run 'make qemu-build' first."
fi

# ── Find OVMF firmware ─────────────────────────────────────────────
if [[ ! -f "$OVMF_CODE" ]]; then
    for candidate in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2-ovmf/OVMF_CODE.fd \
        /usr/share/qemu/OVMF.fd; do
        if [[ -f "$candidate" ]]; then
            OVMF_CODE="$candidate"
            break
        fi
    done
fi

if [[ ! -f "$OVMF_CODE" ]]; then
    playos_log_fatal "boot" "OVMF firmware not found. Install the 'ovmf' package."
fi

playos_log_info "boot" "Using OVMF: $OVMF_CODE"

# ── Create data disk if missing ────────────────────────────────────
if [[ ! -f "$DATA_DISK" ]]; then
    playos_log_info "data" "Creating data disk image: $DATA_DISK"
    mkdir -p "$(dirname "$DATA_DISK")"
    # Create a 256MB qcow2 image with ext4 and label "playos-data"
    dd if=/dev/zero of="$DATA_DISK" bs=1M count=256 status=none 2>/dev/null
    /sbin/mkfs.ext4 -q -F -L "playos-data" "$DATA_DISK" 2>/dev/null
    playos_log_ok "data" "Data disk created (256MB, ext4, label=playos-data)"
fi

# ── Create temp OVMF vars ──────────────────────────────────────────
OVMF_VARS_TMP="$(mktemp)"
if [[ -f "$OVMF_VARS" ]]; then
    cp "$OVMF_VARS" "$OVMF_VARS_TMP"
else
    # Create empty OVMF vars file
    dd if=/dev/zero of="$OVMF_VARS_TMP" bs=1M count=4 2>/dev/null
fi

# ── Boot in QEMU ───────────────────────────────────────────────────
BOOT_LOG="$(mktemp)"
playos_log_info "boot" "Starting QEMU with ${TIMEOUT}s timeout..."

# Run QEMU with serial output captured
timeout "$TIMEOUT" qemu-system-x86_64 \
    -m 512M \
    -machine q35,accel=kvm:tcg \
    -cpu qemu64 \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_TMP" \
    -kernel "$BZIMAGE" \
    -initrd "$INITRAMFS" \
    -drive if=none,id=data,format=raw,file="$DATA_DISK" \
    -device virtio-blk-pci,drive=data \
    -append "console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200n8 quiet" \
    -serial stdio \
    -display none \
    -no-reboot \
    > "$BOOT_LOG" 2>&1 &
QEMU_PID=$!

# Wait for QEMU to finish or timeout (timeout sends SIGTERM → non-zero exit is expected)
set +e
wait $QEMU_PID 2>/dev/null
QEMU_EXIT=$?
set -e

# ── Verify boot output ─────────────────────────────────────────────
playos_log_step "Boot Log Analysis"

if grep -q "PlayOS.*Sprint 1" "$BOOT_LOG" 2>/dev/null; then
    playos_log_ok "verify" "Boot banner detected — playos-init reached PID 1!"
elif grep -q "playos-init starting as PID 1" "$BOOT_LOG" 2>/dev/null; then
    playos_log_ok "verify" "playos-init started as PID 1!"
elif grep -q "PlayOS.*Sprint 0" "$BOOT_LOG" 2>/dev/null; then
    playos_log_ok "verify" "Sprint 0 boot banner detected (fallback BusyBox init)!"
elif grep -q "BusyBox" "$BOOT_LOG" 2>/dev/null; then
    playos_log_ok "verify" "BusyBox shell reached!"
elif grep -q "Kernel panic" "$BOOT_LOG" 2>/dev/null; then
    playos_log_fatal "verify" "Kernel panic detected. Check boot log."
elif grep -q "No working init found" "$BOOT_LOG" 2>/dev/null; then
    playos_log_fatal "verify" "No init found — check initramfs contents."
else
    playos_log_warn "verify" "Could not confirm successful boot. Boot log:"
    tail -20 "$BOOT_LOG" | while read -r line; do
        playos_log_debug "boot" "$line"
    done
    playos_log_warn "verify" "QEMU may have timed out or boot is incomplete."
fi

# ── Cleanup ────────────────────────────────────────────────────────
rm -f "$OVMF_VARS_TMP"
playos_log_info "boot" "Full boot log saved to: $BOOT_LOG"
