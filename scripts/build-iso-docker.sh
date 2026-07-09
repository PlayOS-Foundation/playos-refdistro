#!/usr/bin/env bash
set -euo pipefail

ROOT="/workspace"
PROFILE="$ROOT/archiso/profiles/playos"
OUT="$ROOT/out"
WORK="/tmp/playos-archiso-work"

if [ ! -d "$PROFILE" ]; then
  echo "Missing archiso profile: $PROFILE"
  echo "Run scripts/init-archiso-profile.sh first."
  exit 1
fi

mkdir -p "$OUT"
rm -rf "$WORK"

mkarchiso -v \
  -w "$WORK" \
  -o "$OUT" \
  "$PROFILE"
