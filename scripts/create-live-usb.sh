#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [path-to.iso]

Write a PlayOS ISO to a selected removable USB device.

Arguments:
  path-to.iso  ISO image to write. When omitted, uses the newest ISO in
               $ROOT/out.

Options:
  -h, --help   Show this help message.

Example:
  $(basename "$0") "$ROOT/out/alpine-playos-v3.24-x86_64.iso"

The script prompts for a removable device and requires typing YES before
destroying its contents.
EOF
}

# ── find the newest ISO ──────────────────────────────────────────────
if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
fi

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 1
fi

if [[ $# -eq 1 ]]; then
    ISO="$(readlink -f "$1")"
else
    ISO="$(find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' -printf '%T@ %p\n' \
        | sort -nr \
        | head -n 1 \
        | cut -d' ' -f2-)"
fi

if [[ -z "${ISO:-}" || ! -f "$ISO" ]]; then
    echo "error: no ISO found; pass one explicitly or build it first" >&2
    exit 1
fi

ISO_SIZE="$(stat --printf=%s "$ISO")"
ISO_SIZE_HUMAN="$(numfmt --to=iec "$ISO_SIZE")"
echo "ISO : $(basename "$ISO") (${ISO_SIZE_HUMAN})"
echo

# ── detect USB devices (removable, non-system disks) ──────────────────
echo "Scanning for USB devices..."
echo

mapfile -t USB_DEVS < <(
    lsblk -ndo NAME,SIZE,RM,TYPE,MODEL,LABEL -b \
    | awk '($3 == 1 || /usb/i) && $4 == "disk"' \
    | sort
)

if [[ ${#USB_DEVS[@]} -eq 0 ]]; then
    echo "error: no removable USB devices found. Plug one in and try again." >&2
    exit 1
fi

echo "Available USB devices:"
echo "────────────────────────────────────────────────────────────────────"
for i in "${!USB_DEVS[@]}"; do
    IFS=' ' read -r name size rm type model label <<< "${USB_DEVS[$i]}"
    size_human="$(numfmt --to=iec "$size")"
    dev_path="/dev/${name}"
    [[ -n "$model" ]] && model_str=" ($model)" || model_str=""
    [[ -n "$label" ]] && label_str=" [$label]" || label_str=""
    printf "%2d) %-10s %8s%s%s\n" "$((i+1))" "$dev_path" "$size_human" "$model_str" "$label_str"
done
echo "────────────────────────────────────────────────────────────────────"
echo

# ── user selection ───────────────────────────────────────────────────
while true; do
    read -rp "Select device number (or 'q' to quit): " choice
    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        echo "Aborted."
        exit 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#USB_DEVS[@]} )); then
        break
    fi
    echo "Invalid choice. Pick 1–${#USB_DEVS[@]} or 'q'."
done

SELECTED="${USB_DEVS[$((choice-1))]}"
IFS=' ' read -r name size rm type model label <<< "$SELECTED"
DEV="/dev/${name}"
DEV_SIZE_HUMAN="$(numfmt --to=iec "$size")"

# ── safety checks ────────────────────────────────────────────────────
if (( size < ISO_SIZE )); then
    echo "error: $DEV is ${DEV_SIZE_HUMAN} — too small for ${ISO_SIZE_HUMAN} ISO." >&2
    exit 1
fi

PARTITIONS="$(lsblk -no NAME "$DEV" | tail -n +2)"
if [[ -n "$PARTITIONS" ]]; then
    echo "WARNING: $DEV has existing partitions:"
    lsblk "$DEV"
    echo
fi

echo "About to write to: $DEV (${DEV_SIZE_HUMAN})"
echo "All data on $DEV will be DESTROYED."
echo

while true; do
    read -rp "Type 'YES' to confirm: " confirm
    if [[ "$confirm" == "YES" ]]; then
        break
    fi
    if [[ "$confirm" == "q" || "$confirm" == "Q" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo "Type 'YES' exactly to proceed, or 'q' to quit."
done

# ── flush any mounted partitions ─────────────────────────────────────
echo
echo "Unmounting any mounted partitions on $DEV..."
for mp in $(lsblk -no MOUNTPOINT "$DEV" 2>/dev/null || true); do
    if [[ -n "$mp" ]]; then
        umount "$mp" 2>/dev/null || true
    fi
done

# ── write ISO ────────────────────────────────────────────────────────
echo "Writing $ISO to $DEV (this may take a few minutes)..."

dd if="$ISO" of="$DEV" bs=4M status=progress conv=fsync oflag=direct 2>&1 || {
    echo "error: dd failed. The USB may be unusable until rewritten." >&2
    exit 1
}

sync

# ── verify apkovl on USB ────────────────────────────────────────────
echo
echo "Verifying apkovl integrity on USB..."
VERIFY_DIR="$(mktemp -d)"
trap 'umount "$VERIFY_DIR" 2>/dev/null; rmdir "$VERIFY_DIR"' EXIT

mount -o loop,ro "$DEV" "$VERIFY_DIR" 2>/dev/null || {
    echo "warning: could not mount USB for verification." >&2
    echo "Done! $DEV has been written."
    exit 0
}

if [[ -f "$VERIFY_DIR/playos.apkovl.tar.gz" ]]; then
    if gzip -t "$VERIFY_DIR/playos.apkovl.tar.gz" 2>/dev/null; then
        APKOVL_SIZE="$(stat --printf=%s "$VERIFY_DIR/playos.apkovl.tar.gz")"
        APKOVL_HUMAN="$(numfmt --to=iec "$APKOVL_SIZE")"
        echo "  ✅ apkovl is valid (${APKOVL_HUMAN})"
    else
        echo "  ❌ apkovl is corrupted!"
    fi
fi

if [[ -f "$VERIFY_DIR/playos-gpt-x86_64.img.zst" || -f "$VERIFY_DIR/playos-gpt-v3.24-x86_64.img.zst" ]]; then
    echo "  ✅ disk image present"
fi

umount "$VERIFY_DIR"
rmdir "$VERIFY_DIR"
trap - EXIT

echo
echo "Done! $DEV is ready. Boot from it and test."
