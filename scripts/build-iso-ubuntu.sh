#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOTFS="$ROOT/.build/alpine-rootfs"
MARKER="$ROOTFS/.playos-alpine-version"

if [[ ! -f "$MARKER" ]]; then
    echo "error: Alpine build root is not initialized" >&2
    echo "Run: bash scripts/setup-ubuntu-build-host.sh" >&2
    exit 1
fi

mkdir -p "$ROOT/out"

sudo systemd-nspawn     --quiet     --directory="$ROOTFS"     --resolv-conf=replace-host     --bind="$ROOT:/workspace"     --setenv="PLAYOS_ROOT=/workspace"     --setenv="PLAYOS_ALPINE_BRANCH=${PLAYOS_ALPINE_BRANCH:-v3.24}"     --setenv="PLAYOS_APORTS_BRANCH=${PLAYOS_APORTS_BRANCH:-3.24-stable}"     --setenv="PLAYOS_ARCH=${PLAYOS_ARCH:-x86_64}"     /bin/bash /workspace/scripts/build-alpine-iso.sh

sudo chown -R "$(id -u):$(id -g)" "$ROOT/out"

echo
echo "Built images:"
find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' -exec ls -lh {} \;
