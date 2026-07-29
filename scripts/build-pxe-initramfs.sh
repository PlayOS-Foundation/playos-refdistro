#!/usr/bin/env bash
# Build a PXE-only initramfs from an Alpine live-image initramfs.
#
# Alpine's nlplug-findfs coldplugs hardware and waits indefinitely while
# searching for removable boot media. PXE still needs the coldplug phase for
# USB Ethernet, but has no local boot medium. Bound it by wall-clock time in
# this derived artifact; the ISO initramfs remains unchanged for USB boot.

set -euo pipefail

ROOT="${PLAYOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── Initialize logging ──────────────────────────────────────────────────────
source "$ROOT/shared/logging-helpers.sh"

if [[ $# -ne 2 ]]; then
    _log_error "Usage: $0 <input-initramfs> <output-initramfs>"
    exit 2
fi

INPUT_INITRAMFS=$1
OUTPUT_INITRAMFS=$2
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if [[ ! -f "$INPUT_INITRAMFS" ]]; then
    _log_error "input initramfs does not exist: $INPUT_INITRAMFS"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_INITRAMFS")"
gzip -cd "$INPUT_INITRAMFS" | (
    cd "$WORKDIR"
    cpio -id --quiet
)

INIT="$WORKDIR/init"
if [[ ! -f "$INIT" ]]; then
    _log_error "extracted initramfs has no /init"
    exit 1
fi

if ! grep -q '\$MOCK nlplug-findfs' "$INIT"; then
    _log_error "extracted initramfs does not contain the expected nlplug-findfs invocation"
    exit 1
fi

# The initramfs contains BusyBox but not necessarily its timeout symlink. A
# timeout is an expected outcome here, so convert it to success and continue
# with the network repository instead of entering Alpine's recovery shell.
sed -i 's/\$MOCK nlplug-findfs/\$MOCK \/usr\/bin\/busybox timeout 15 nlplug-findfs/g' "$INIT"
sed -i '/\$repoopts -a "\$ROOT"\/tmp\/apkovls/s/$/ || true/' "$INIT"

(
    cd "$WORKDIR"
    find . -print | cpio -o -H newc --quiet | gzip -9n > "$OUTPUT_INITRAMFS"
)
