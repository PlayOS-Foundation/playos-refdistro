#!/usr/bin/env bash
set -euo pipefail

ALPINE_VERSION="${PLAYOS_ALPINE_VERSION:-3.24.1}"
ALPINE_BRANCH="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$ROOT/.build"
CACHE="$BUILD_ROOT/cache"
ROOTFS="$BUILD_ROOT/alpine-rootfs"
MARKER="$ROOTFS/.playos-alpine-version"

if [[ ! -r /etc/os-release ]]; then
    echo "error: /etc/os-release is unavailable" >&2
    exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "error: this setup wrapper targets Ubuntu Server" >&2
    exit 1
fi

echo "==> Installing Ubuntu host dependencies"
sudo apt-get update
sudo apt-get install -y     ca-certificates     curl     git     ovmf     qemu-system-x86     systemd-container     xz-utils

BASE_URL="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/$ARCH"
ARCHIVE="alpine-minirootfs-$ALPINE_VERSION-$ARCH.tar.gz"
URL="$BASE_URL/$ARCHIVE"

mkdir -p "$CACHE"
if [[ ! -f "$CACHE/$ARCHIVE" ]]; then
    echo "==> Downloading $URL"
    curl --fail --location --output "$CACHE/$ARCHIVE" "$URL"
fi

echo "==> Verifying Alpine minirootfs checksum"
curl --fail --location --output "$CACHE/$ARCHIVE.sha256" "$URL.sha256"
(
    cd "$CACHE"
    sha256sum --check "$ARCHIVE.sha256"
)

if [[ -f "$MARKER" ]]; then
    installed_version="$(sudo cat "$MARKER")"
    if [[ "$installed_version" != "$ALPINE_VERSION-$ARCH" ]]; then
        echo "error: $ROOTFS contains Alpine $installed_version" >&2
        echo "Move that directory aside before changing versions." >&2
        exit 1
    fi
elif [[ -d "$ROOTFS" ]] && [[ -n "$(sudo find "$ROOTFS" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "error: $ROOTFS is non-empty but has no PlayOS version marker" >&2
    echo "Move it aside and run this script again." >&2
    exit 1
else
    echo "==> Extracting Alpine minirootfs"
    sudo mkdir -p "$ROOTFS"
    sudo tar --extract --gzip --numeric-owner         --file "$CACHE/$ARCHIVE"         --directory "$ROOTFS"
    echo "$ALPINE_VERSION-$ARCH" | sudo tee "$MARKER" >/dev/null
fi

echo "==> Installing Alpine build dependencies in systemd-nspawn"
sudo systemd-nspawn     --quiet     --directory="$ROOTFS"     --resolv-conf=replace-host     --bind-ro="$ROOT:/workspace"     --setenv="PLAYOS_ALPINE_BRANCH=$ALPINE_BRANCH"     --setenv="TMPDIR=/var/tmp"     /bin/sh /workspace/scripts/install-alpine-build-deps.sh

cat <<EOF

Ubuntu build host is ready.

Alpine rootfs: $ROOTFS
Next command:
  bash scripts/build-iso-ubuntu.sh
EOF
