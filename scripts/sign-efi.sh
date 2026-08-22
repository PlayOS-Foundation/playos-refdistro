#!/bin/sh
# PlayOS EFI signing (S12-T9) — development signing
#
# Signs an EFI binary (BOOTX64.EFI) with the PlayOS development EFI
# signing key using sbsign. Production signing uses an HSM-backed key
# (post-MVP); this script exists so CI can exercise the full chain.
#
# Usage:
#   scripts/sign-efi.sh <input.efi> [output.efi]
#
# Requires sbsign (Buildroot host package sbsign / host-sbsign).
set -eu

INPUT="${1:?usage: sign-efi.sh <input.efi> [output.efi]}"
OUTPUT="${2:-$INPUT.signed.efi}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY="$SCRIPT_DIR/../keys/dev/efi-signing-key.pem"
CERT="$SCRIPT_DIR/../keys/dev/efi-signing-cert.pem"

if ! command -v sbsign >/dev/null 2>&1; then
    echo "error: sbsign not found (install host-sbsign)" >&2
    exit 1
fi

exec sbsign --key "$KEY" --cert "$CERT" --output "$OUTPUT" "$INPUT"
