#!/bin/sh
# PlayOS manifest signing (S12-T8) — development signing
#
# Signs a game manifest.json with the PlayOS development Ed25519 key,
# producing a raw 64-byte detached signature at manifest.json.sig.
#
# Usage:
#   scripts/sign-manifest.sh <path-to-manifest.json>
#
# The matching public key is embedded in playos-init
# (src/security/game_key.h); verification is warn-only in the MVP.
# This is a DEVELOPMENT key — production game signing is store-side
# (post-MVP) with a separate key.
set -eu

MANIFEST="${1:?usage: sign-manifest.sh <manifest.json>}"
KEY_DIR="$(cd "$(dirname "$0")/../keys/dev" && pwd)"
SEED_FILE="$KEY_DIR/manifest-key.sec"
OUT="$MANIFEST.sig"

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 required (with cryptography)" >&2
    exit 1
fi

python3 - "$MANIFEST" "$SEED_FILE" "$OUT" <<'PYEOF'
import sys
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

manifest_path, seed_path, out_path = sys.argv[1:4]
seed = bytes.fromhex(Path(seed_path).read_text().strip())
assert len(seed) == 32, "manifest dev seed must be 32 bytes"

sk = Ed25519PrivateKey.from_private_bytes(seed)
sig = sk.sign(Path(manifest_path).read_bytes())
Path(out_path).write_bytes(sig)
print(f"signed: {manifest_path} -> {out_path}")
PYEOF
