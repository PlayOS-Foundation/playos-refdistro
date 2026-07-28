#!/usr/bin/env bash
# setup-ubuntu-build-host.sh — Prepare Ubuntu host for PlayOS image builds.
#
# Supports two distro backends:
#   PLAYOS_DISTRO=alpine (default) — Alpine minirootfs + apk build deps
#   PLAYOS_DISTRO=arch              — Arch bootstrap tarball + pacman build deps
#
# Usage:
#   bash scripts/setup-ubuntu-build-host.sh                    # Alpine only
#   PLAYOS_DISTRO=arch bash scripts/setup-ubuntu-build-host.sh # Arch only
#   bash scripts/setup-ubuntu-build-host.sh && PLAYOS_DISTRO=arch bash scripts/setup-ubuntu-build-host.sh  # both
set -euo pipefail

DISTRO="${PLAYOS_DISTRO:-alpine}"
ALPINE_VERSION="${PLAYOS_ALPINE_VERSION:-3.24.1}"
ALPINE_BRANCH="${PLAYOS_ALPINE_BRANCH:-v3.24}"
ARCH="${PLAYOS_ARCH:-x86_64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$ROOT/.build"
CACHE="$BUILD_ROOT/cache"

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
sudo apt-get install -y \
    ca-certificates \
    curl \
    git \
    ovmf \
    qemu-system-x86 \
    systemd-container \
    xz-utils \
    zstd

# ── Distro-specific setup functions ──────────────────────────────────────────

setup_alpine() {
    local ROOTFS="$BUILD_ROOT/alpine-rootfs"
    local MARKER="$ROOTFS/.playos-alpine-version"
    local BASE_URL="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/$ARCH"
    local ARCHIVE="alpine-minirootfs-$ALPINE_VERSION-$ARCH.tar.gz"
    local URL="$BASE_URL/$ARCHIVE"

    mkdir -p "$CACHE"
    if [[ ! -f "$CACHE/$ARCHIVE" ]]; then
        echo "==> [Alpine] Downloading $URL"
        curl --fail --location --output "$CACHE/$ARCHIVE" "$URL"
    fi

    echo "==> [Alpine] Verifying minirootfs checksum"
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
        echo "==> [Alpine] Extracting minirootfs"
        sudo mkdir -p "$ROOTFS"
        sudo tar --extract --gzip --numeric-owner \
            --file "$CACHE/$ARCHIVE" \
            --directory "$ROOTFS"
        echo "$ALPINE_VERSION-$ARCH" | sudo tee "$MARKER" >/dev/null
    fi

    echo "==> [Alpine] Installing build dependencies in systemd-nspawn"
    sudo systemd-nspawn \
        --quiet \
        --directory="$ROOTFS" \
        --resolv-conf=replace-host \
        --bind-ro="$ROOT:/workspace" \
        --setenv="PLAYOS_ALPINE_BRANCH=$ALPINE_BRANCH" \
        --setenv="TMPDIR=/var/tmp" \
        /bin/sh /workspace/scripts/install-alpine-build-deps.sh
}

setup_arch() {
    local ROOTFS="$BUILD_ROOT/arch-rootfs"
    local MARKER="$ROOTFS/.playos-arch-version"
    local SNAPSHOT_DATE="${PLAYOS_ARCH_SNAPSHOT:-2026/07/01}"
    # Use a recent Arch bootstrap tarball — version pinned for reproducibility
    local BOOTSTRAP_VER="${PLAYOS_ARCH_BOOTSTRAP_VER:-2026.07.01}"
    local BOOTSTRAP_URL="https://geo.mirror.pkgbuild.com/iso/${BOOTSTRAP_VER}/archlinux-bootstrap-${BOOTSTRAP_VER}-x86_64.tar.zst"
    local BOOTSTRAP_ARCHIVE="archlinux-bootstrap-${BOOTSTRAP_VER}-x86_64.tar.zst"

    if [[ -f "$MARKER" ]]; then
        installed_version="$(sudo cat "$MARKER")"
        if [[ "$installed_version" != "$SNAPSHOT_DATE-$ARCH" ]]; then
            echo "error: $ROOTFS contains Arch snapshot $installed_version" >&2
            echo "Move that directory aside before changing snapshots." >&2
            exit 1
        fi
    elif [[ -d "$ROOTFS" ]] && [[ -n "$(sudo find "$ROOTFS" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "error: $ROOTFS is non-empty but has no PlayOS version marker" >&2
        echo "Move it aside and run this script again." >&2
        exit 1
    else
        mkdir -p "$CACHE"

        # Download Arch bootstrap tarball
        if [[ ! -f "$CACHE/$BOOTSTRAP_ARCHIVE" ]]; then
            echo "==> [Arch] Downloading bootstrap tarball: $BOOTSTRAP_URL"
            curl --fail --location --output "$CACHE/$BOOTSTRAP_ARCHIVE" "$BOOTSTRAP_URL"
        fi

        echo "==> [Arch] Extracting bootstrap tarball"
        sudo mkdir -p "$ROOTFS"
        sudo tar --extract --zstd --numeric-owner \
            --file "$CACHE/$BOOTSTRAP_ARCHIVE" \
            --directory "$ROOTFS" \
            --strip-components=1

        echo "$SNAPSHOT_DATE-$ARCH" | sudo tee "$MARKER" >/dev/null

        # Copy PlayOS pacman.conf + mirrors (bootstrap ships with mirrors commented out)
        echo "==> [Arch] Installing pacman.conf and mirrorlists"
        sudo cp "$ROOT/arch/pacman.conf" "$ROOTFS/etc/pacman.conf"
        sudo mkdir -p "$ROOTFS/etc/pacman.d"
        sudo cp "$ROOT/arch/cachyos-mirrorlist" "$ROOTFS/etc/pacman.d/cachyos-mirrorlist"

        # First nspawn: initialize pacman keyring + install base
        echo "==> [Arch] Initializing pacman keyring"
        sudo systemd-nspawn \
            --quiet \
            --directory="$ROOTFS" \
            --resolv-conf=replace-host \
            /bin/sh -c '
                set -e
                pacman-key --init
                pacman-key --populate archlinux
                pacman -Syu --noconfirm --disable-download-timeout
            '

        # Install build deps via nspawn
        echo "==> [Arch] Installing build dependencies"
        sudo systemd-nspawn \
            --quiet \
            --directory="$ROOTFS" \
            --resolv-conf=replace-host \
            --bind-ro="$ROOT:/workspace" \
            --setenv="PLAYOS_KERNEL_VARIANT=${PLAYOS_KERNEL_VARIANT:-cachyos}" \
            --setenv="PLAYOS_ARCH=$ARCH" \
            --setenv="TMPDIR=/var/tmp" \
            /bin/sh /workspace/scripts/install-arch-build-deps.sh
    fi
}

case "$DISTRO" in
    alpine) ROOTFS="$BUILD_ROOT/alpine-rootfs"; setup_alpine ;;
    arch)   ROOTFS="$BUILD_ROOT/arch-rootfs";   setup_arch   ;;
    *)
        echo "error: unknown PLAYOS_DISTRO=$DISTRO (expect alpine or arch)" >&2
        exit 1
        ;;
esac

cat <<EOF

Ubuntu build host is ready for $DISTRO.

Build root: $ROOTFS
Next command:
  PLAYOS_DISTRO=$DISTRO bash scripts/build-iso-ubuntu.sh
EOF
