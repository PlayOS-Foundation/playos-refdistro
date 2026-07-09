#!/usr/bin/env bash
set -euo pipefail

ROOT="/workspace"
PROFILE_ROOT="$ROOT/archiso/profiles"
PROFILE="$PROFILE_ROOT/playos"

mkdir -p "$PROFILE_ROOT"

if [ -d "$PROFILE" ]; then
  echo "Profile already exists: $PROFILE"
  exit 0
fi

cp -r /usr/share/archiso/configs/baseline "$PROFILE"

echo "Created PlayOS archiso profile at: $PROFILE"
