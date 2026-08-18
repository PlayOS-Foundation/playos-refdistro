#!/usr/bin/env bash
# create-update-bundle.sh — Build a dev-signed PlayOS update bundle (.playosb)
#
# Usage:
#   scripts/create-update-bundle.sh <rootfs.squashfs> <version> <output.playosb>
#
# Bundle layout (all multi-byte integers little-endian):
#   [4B magic "PBS1"][4B header_len][header_len bytes JSON header]
#   [payload = raw squashfs bytes][4B sig_len][sig_len bytes lowercase hex HMAC-SHA256]
#
# The HMAC-SHA256 signature is computed over every byte from offset 0 up to
# (but excluding) the trailing 4-byte sig_len field — i.e. magic + header_len +
# header + payload. sig_len is the byte length of the lowercase hex signature.
#
# Development key only — NOT for production images.

set -euo pipefail

HMAC_KEY="playos-dev-update-key-not-for-production"
MAGIC="PBS1"

# Emit a 32-bit unsigned integer as 4 little-endian bytes on stdout.
le32() {
    local value=$1
    printf "\\$(printf '%03o' $(( value        & 0xff )))\\$(printf '%03o' $(( (value >> 8)  & 0xff )))\\$(printf '%03o' $(( (value >> 16) & 0xff )))\\$(printf '%03o' $(( (value >> 24) & 0xff )))"
}

SQUASHFS="${1:-}"
VERSION="${2:-}"
OUTPUT="${3:-}"

if [[ -z "$SQUASHFS" ]]; then
    echo "ERROR: Missing <rootfs.squashfs> argument." >&2
    echo "Usage: $0 <rootfs.squashfs> <version> <output.playosb>" >&2
    exit 1
fi
if [[ -z "$VERSION" ]]; then
    echo "ERROR: version must be non-empty." >&2
    echo "Usage: $0 <rootfs.squashfs> <version> <output.playosb>" >&2
    exit 1
fi
if [[ -z "$OUTPUT" ]]; then
    echo "ERROR: Missing <output.playosb> argument." >&2
    echo "Usage: $0 <rootfs.squashfs> <version> <output.playosb>" >&2
    exit 1
fi
if [[ ! -f "$SQUASHFS" ]]; then
    echo "ERROR: rootfs.squashfs not found: $SQUASHFS" >&2
    exit 1
fi

PAYLOAD_SIZE=$(stat -c%s "$SQUASHFS")
PAYLOAD_SHA256=$(sha256sum "$SQUASHFS" | awk '{print $1}')

# JSON header, no trailing newline.
HEADER=$(printf '{"format":"playosb-1","version":"%s","payload_size":%s,"payload_sha256":"%s","sig_alg":"hmac-sha256-dev"}' \
    "$VERSION" "$PAYLOAD_SIZE" "$PAYLOAD_SHA256")
HEADER_LEN=$(printf '%s' "$HEADER" | wc -c | awk '{print $1}')

# Write atomically: build in the destination directory, then mv into place
# only after every byte (including the signature) has been written.
OUTPUT_DIR=$(dirname "$OUTPUT")
mkdir -p "$OUTPUT_DIR"

TMP_OUT=$(mktemp "$OUTPUT_DIR/.create-update-bundle.XXXXXX")
cleanup() {
    rm -f "$TMP_OUT"
}
trap cleanup EXIT

# magic + header_len + header + payload
printf '%s' "$MAGIC" > "$TMP_OUT"
le32 "$HEADER_LEN" >> "$TMP_OUT"
printf '%s' "$HEADER" >> "$TMP_OUT"
dd if="$SQUASHFS" of="$TMP_OUT" oflag=append conv=notrunc bs=1M status=none

# Sign everything written so far (magic + header_len + header + payload).
SIG_HEX=$(openssl dgst -sha256 -hmac "$HMAC_KEY" "$TMP_OUT" | awk '{print $NF}')
SIG_LEN=$(printf '%s' "$SIG_HEX" | wc -c | awk '{print $1}')

# sig_len + sig
le32 "$SIG_LEN" >> "$TMP_OUT"
printf '%s' "$SIG_HEX" >> "$TMP_OUT"

mv "$TMP_OUT" "$OUTPUT"
trap - EXIT

echo "==> Update bundle created: $OUTPUT"
echo "==> payload_size=$PAYLOAD_SIZE  header_len=$HEADER_LEN  sig_len=$SIG_LEN"
