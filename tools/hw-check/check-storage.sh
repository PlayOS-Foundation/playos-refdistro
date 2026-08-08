#!/bin/sh
# check-storage.sh — Verify NVMe and block storage devices
#
# Checks:
#   - NVMe block devices exist
#   - Partitions are readable
#   - USB boot media is detected
#
# Output format: [OK] / [FAIL] / [SKIP] <message>

HW_LOG="/run/playos/hw-check.log"
mkdir -p /run/playos

log() { echo "$@" | tee -a "$HW_LOG"; }

log "=== STORAGE ==="

# Check NVMe devices
NVME_COUNT=0
for nvme in /dev/nvme*; do
    if [ -e "$nvme" ]; then
        NVME_COUNT=$((NVME_COUNT + 1))
        log "[OK]  NVMe device: $nvme"
        
        # Check if partitions are readable
        for part in ${nvme}p* ${nvme}n1p*; do
            if [ -b "$part" ]; then
                SIZE=$(cat "/sys/class/block/$(basename "$part")/size" 2>/dev/null || echo "unknown")
                log "      Partition: $part (sectors: $SIZE)"
            fi
        done
    fi
    break  # Only first nvme device
done

if [ "$NVME_COUNT" -eq 0 ]; then
    log "[WARN] No NVMe devices found"
fi

# Check other block devices (USB boot media, etc.)
log "[INFO] Block device summary:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL 2>/dev/null | while IFS= read -r line; do
    log "      $line"
done

# Check for the boot USB device (typically sda or similar)
BOOT_DEV=""
for dev in /dev/sd?; do
    if [ -b "$dev" ]; then
        DEV_NAME=$(basename "$dev")
        SIZE=$(cat "/sys/class/block/$DEV_NAME/size" 2>/dev/null || echo "unknown")
        log "[OK]  USB/removable device: $dev (sectors: $SIZE)"
        BOOT_DEV="$dev"
    fi
done

if [ -z "$BOOT_DEV" ]; then
    log "[INFO] No USB/SD block devices found — booted from internal storage?"
fi

# Check mounted filesystems
log "[INFO] Mounted filesystems:"
mount | while IFS= read -r line; do
    log "      $line"
done

echo ""
