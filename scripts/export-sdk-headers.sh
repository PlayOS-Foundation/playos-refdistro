#!/bin/sh
# export-sdk-headers.sh — package libplayos + raylib public headers (S14-T9)
#
# Produces a headers-only SDK tarball: playos/include/playos/*.h + raylib.h.
# Sprint 15 turns this into the full toolchain+libs SDK.
#
# Usage:
#   scripts/export-sdk-headers.sh [version] [output.tar.gz]
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-0.3.0}"
OUT="${2:-$REPO_DIR/output/playos-$VERSION-sdk-headers.tar.gz}"

PLAYOS_INC="$REPO_DIR/src/playos-platform-api/include/playos"
RAYLIB_H="$REPO_DIR/src/playos-shell/external/raylib/src/raylib.h"

if [ ! -d "$PLAYOS_INC" ]; then
    echo "ERROR: libplayos headers not found at $PLAYOS_INC" >&2
    echo "Run 'make setup' first (clones pinned component repos into src/)." >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/playos/include/playos" "$STAGE/playos/include/raylib"
cp "$PLAYOS_INC/"*.h "$STAGE/playos/include/playos/"

if [ -f "$RAYLIB_H" ]; then
    cp "$RAYLIB_H" "$STAGE/playos/include/raylib/"
fi

cat > "$STAGE/playos/README.md" <<EOF
# PlayOS SDK headers (v$VERSION)

Headers-only SDK for the frozen public API (PLAYOS_API_VERSION 1).

- include/playos/  — libplayos public C headers
- include/raylib/  — raylib.h (PLATFORM_PLAYOS backend, from playos-shell)

The full toolchain + libraries SDK ships in a later milestone (Sprint 15).
EOF

mkdir -p "$(dirname "$OUT")"
tar -C "$STAGE" -czf "$OUT" playos
echo "==> SDK headers: $OUT"
