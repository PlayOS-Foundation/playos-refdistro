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

# PlayOS source repos (sibling directories).
RUNTIME_SRC="${PLAYOS_RUNTIME_SRC:-$ROOT/../playos-runtime}"
SHELL_SRC="${PLAYOS_SHELL_SRC:-$ROOT/../playos-shell}"
PLATFORM_SRC="${PLAYOS_PLATFORM_SRC:-$ROOT/../playos-platform-api}"
SAMPLES_SRC="${PLAYOS_SAMPLES_SRC:-$ROOT/../playos-samples}"

echo "==> Building PlayOS compositor + shell + ISO"

sudo systemd-nspawn \
    --quiet \
    --directory="$ROOTFS" \
    --resolv-conf=replace-host \
    --bind="$ROOT:/workspace" \
    --bind="$RUNTIME_SRC:/mnt/playos-runtime" \
    --bind="$SHELL_SRC:/mnt/playos-shell" \
    --bind="$PLATFORM_SRC:/mnt/playos-platform-api" \
    --bind="$SAMPLES_SRC:/mnt/playos-samples" \
    --setenv="PLAYOS_ROOT=/workspace" \
    --setenv="PLAYOS_RUNTIME_SRC=/mnt/playos-runtime" \
    --setenv="PLAYOS_SHELL_SRC=/mnt/playos-shell" \
    --setenv="PLAYOS_PLATFORM_SRC=/mnt/playos-platform-api" \
    --setenv="PLAYOS_SAMPLES_SRC=/mnt/playos-samples" \
    --setenv="PLAYOS_ALPINE_BRANCH=${PLAYOS_ALPINE_BRANCH:-v3.24}" \
    --setenv="PLAYOS_APORTS_BRANCH=${PLAYOS_APORTS_BRANCH:-3.24-stable}" \
    --setenv="PLAYOS_ARCH=${PLAYOS_ARCH:-x86_64}" \
    --setenv="TMPDIR=/var/tmp" \
    /bin/sh -c '
        set -e
        /workspace/scripts/build-playos-components.sh
        /workspace/scripts/build-alpine-iso.sh
    '

sudo chown -R "$(id -u):$(id -g)" "$ROOT/out"

echo
echo "Built images:"
find "$ROOT/out" -maxdepth 1 -type f -name '*.iso' -exec ls -lh {} \;

# === Deploy to PXE server ===
PXE_DIR="/var/www/html/playos"
echo
echo "==> Deploying to PXE server: $PXE_DIR"

# Generate APK cache from world packages so netboot clients can resolve deps.
# Use the freshly built rootfs apk cache as the base.
APK_CACHE="$PXE_DIR/apks"
mkdir -p "$APK_CACHE"

# Fetch all required packages from the world file into the PXE cache
if [ -f "$ROOT/alpine/genapkovl-playos.sh" ]; then
    # Extract the package list from the world file section
    PKGS=$(sed -n '/^cat.*world/,/^EOF$/p' "$ROOT/alpine/genapkovl-playos.sh" | grep -v '^cat\|^EOF$' | tr '\n' ' ')
    echo "  Fetching packages: $PKGS"
    sudo systemd-nspawn \
        --quiet \
        --directory="$ROOTFS" \
        --bind="$APK_CACHE:/var/cache/apk-pxe" \
        /bin/sh -c "
            set -e
            apk update
            apk fetch --output /var/cache/apk-pxe/x86_64 --no-cache $PKGS 2>&1 || true
            apk index -o /var/cache/apk-pxe/x86_64/APKINDEX.tar.gz /var/cache/apk-pxe/x86_64/*.apk 2>&1 || true
        "
    sudo chown -R "$(id -u):$(id -g)" "$APK_CACHE"
    echo "  APK cache updated: $(ls "$APK_CACHE/x86_64"/*.apk 2>/dev/null | wc -l) packages"
fi

# Copy ISO and associated files
cp "$ROOT"/out/*.iso "$PXE_DIR/alpine-playos-${PLAYOS_ALPINE_BRANCH:-v3.24}-${PLAYOS_ARCH:-x86_64}.iso"
cp "$ROOT"/out/*.apkovl.tar.gz "$PXE_DIR/playos.apkovl.tar.gz" 2>/dev/null || true
echo "  Deployed to $PXE_DIR"
ls -lh "$PXE_DIR/"
