#!/usr/bin/env bash
# flash-usb.sh — Detect USB storage devices, confirm, and dd an image
#
# Usage:
#   sudo bash scripts/flash-usb.sh <path/to/image.img>
#
# Lists removable USB block devices, asks user to select one, requires
# confirmation by typing YES, then flashes the image with dd.

set -euo pipefail

IMAGE="${1:-}"
if [[ -z "$IMAGE" ]]; then
    echo "ERROR: No image file specified." >&2
    echo "Usage: $0 <path/to/image.img>" >&2
    exit 1
fi

if [[ ! -f "$IMAGE" ]]; then
    echo "ERROR: Image file not found: $IMAGE" >&2
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

# ── Detect USB storage devices ─────────────────────────────────────
echo "==> Scanning for removable USB storage devices..."
echo ""

# Collect removable USB block devices using lsblk key=value pairs
# (avoids column-splitting bugs from model names with spaces like "SanDisk 3.2Gen1")
DEVICES=()
while IFS= read -r line; do
    DEVICES+=("$line")
done < <(lsblk -d -P -o NAME,SIZE,MODEL,TRAN,RM -n 2>/dev/null | \
    while IFS= read -r entry; do
        eval "$entry"
        if [[ "$TRAN" == "usb" || "$RM" == "1" ]]; then
            printf "%-10s %-10s %s\n" "$NAME" "$SIZE" "$MODEL"
        fi
    done)

if [[ ${#DEVICES[@]} -eq 0 ]]; then
    echo "No removable USB storage devices detected."
    echo ""
    echo "All block devices:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN,TYPE 2>/dev/null | grep -E 'disk|NAME'
    exit 1
fi

echo "   #  DEVICE     SIZE       MODEL"
echo "   -- ---------- ---------- --------------------"
for i in "${!DEVICES[@]}"; do
    printf "   %-2d %s\n" "$((i + 1))" "${DEVICES[$i]}"
done
echo ""

# ── User selection ──────────────────────────────────────────────────
read -r -p "Select device number (1-${#DEVICES[@]}): " SELECTION
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || \
   [[ "$SELECTION" -lt 1 ]] || \
   [[ "$SELECTION" -gt ${#DEVICES[@]} ]]; then
    echo "ERROR: Invalid selection." >&2
    exit 1
fi

SELECTED_LINE="${DEVICES[$((SELECTION - 1))]}"
DEV_NAME="${SELECTED_LINE%% *}"   # first field (padded with space)
DEV_PATH="/dev/$DEV_NAME"

if [[ ! -b "$DEV_PATH" ]]; then
    echo "ERROR: $DEV_PATH is not a valid block device." >&2
    exit 1
fi

# Show additional detail for the selected device
echo ""
echo "  Selected: $DEV_PATH"
lsblk "$DEV_PATH" -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS 2>/dev/null
echo ""

# ── Warning ─────────────────────────────────────────────────────────
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  ⚠  WARNING: THIS WILL ERASE ALL DATA ON $DEV_PATH"
echo "  ╚══════════════════════════════════════════════════════════╝"

# Check for mounted partitions
MOUNTS=$(lsblk -o NAME,MOUNTPOINTS -n "$DEV_PATH" 2>/dev/null | awk '$2 != "" {print $1, $2}')
if [[ -n "$MOUNTS" ]]; then
    echo ""
    echo "  MOUNTED PARTITIONS DETECTED:"
    echo "  $MOUNTS"
    echo "  These will be unmounted before flashing."
fi
echo ""

# ── Confirmation ────────────────────────────────────────────────────
read -r -p "Type YES to confirm and flash: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Unmount any mounted partitions ──────────────────────────────────
PARTITIONS=$(lsblk -o NAME,MOUNTPOINTS -n "$DEV_PATH" 2>/dev/null | awk '$2 != "" {print "/dev/"$1}')
for PART in $PARTITIONS; do
    echo "==> Unmounting $PART..."
    umount "$PART" 2>/dev/null || true
done

# ── Flash the image ─────────────────────────────────────────────────
IMAGE_SIZE=$(du -h "$IMAGE" | cut -f1)
echo ""
echo "==> Flashing $IMAGE ($IMAGE_SIZE) to $DEV_PATH..."
echo "    This may take a few minutes..."
echo ""

dd if="$IMAGE" of="$DEV_PATH" bs=4M status=progress conv=fsync

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║     Flash complete!                              ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
echo "  Image:  $IMAGE"
echo "  Device: $DEV_PATH"
echo ""
echo "  Safe to remove. Boot ROG Ally with Volume Down held."
