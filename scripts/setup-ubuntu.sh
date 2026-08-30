#!/usr/bin/env bash
# setup-ubuntu.sh — Prepare a fresh Ubuntu Server LTS machine for PlayOS development
#
# Usage:
#   bash scripts/setup-ubuntu.sh
#
# Requirements:
#   - Ubuntu 22.04 LTS or later
#   - Internet access for apt package downloads

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared logging
. "$SCRIPT_DIR/lib/playos_log.sh"

playos_log_step "PlayOS Host Environment Setup"

# ── Detect Ubuntu version ──────────────────────────────────────────
playos_log_info "setup" "Detecting Ubuntu version..."

if [[ ! -f /etc/os-release ]]; then
    playos_log_fatal "setup" "Cannot detect OS: /etc/os-release not found. This script requires Ubuntu."
fi

# shellcheck source=/dev/null
. /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    playos_log_fatal "setup" "Unsupported OS: $ID. This script requires Ubuntu."
fi

UBUNTU_MAJOR="${VERSION_ID%%.*}"
if [[ "$UBUNTU_MAJOR" -lt 22 ]]; then
    playos_log_fatal "setup" "Ubuntu $VERSION_ID is too old. Minimum: Ubuntu 22.04 LTS."
fi

playos_log_ok "setup" "Detected $PRETTY_NAME"

# Quiet the "You are in 'detached HEAD' state" advice emitted when the
# Makefile pins Buildroot to a specific commit.
git config --global advice.detachedHead false

# apt-get needs root. GitHub Actions runners run as a non-root user with
# passwordless sudo, so escalate automatically when we are not already root.
if [[ $EUID -eq 0 ]]; then
    APT_GET=(apt-get)
else
    APT_GET=(sudo apt-get)
fi

# ── Required packages ──────────────────────────────────────────────
PACKAGES=(
    # Core build tools
    build-essential gcc g++ make cmake ninja-build meson pkg-config
    # Buildroot host dependencies
    libncurses-dev libssl-dev libelf-dev bison flex cpio rsync
    unzip bc file wget
    # ALSA dev headers (native playos-platform-api build links libasound)
    libasound2-dev
    # Image and boot tooling
    ovmf qemu-system-x86 qemu-utils dosfstools mtools parted
    # Filesystem and EFI tools
    gdisk squashfs-tools
    # Python (for Buildroot scripts)
    python3 python3-pip
    # Git and versioning
    git curl
    # Native Wayland/wlroots host-deps build prerequisites (build-host-deps.sh)
    libexpat1-dev libffi-dev libxml2-dev
    libpciaccess-dev libudev-dev
    libxcb1-dev libxcb-composite0-dev libxcb-dri3-dev
    libxcb-ewmh-dev libxcb-icccm4-dev libxcb-present-dev
    libxcb-randr0-dev libxcb-render0-dev libxcb-render-util0-dev
    libxcb-res0-dev libxcb-shape0-dev libxcb-shm0-dev
    libxcb-sync-dev libxcb-xfixes0-dev libxcb-xinput-dev libxcb-xkb-dev
    libx11-dev libx11-xcb-dev
    libinput-dev libseat-dev libvulkan-dev
    libegl1-mesa-dev libgbm-dev libgles2-mesa-dev
    libdisplay-info-dev libliftoff-dev hwdata
)

playos_log_info "setup" "Updating package lists..."
"${APT_GET[@]}" update -qq

INSTALLED=()
ALREADY=()
FAILED=()

for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
        ALREADY+=("$pkg")
    else
        playos_log_info "setup" "Installing $pkg..."
        if "${APT_GET[@]}" install -y -qq "$pkg" 2>/dev/null; then
            INSTALLED+=("$pkg")
        else
            FAILED+=("$pkg")
        fi
    fi
done

# ── Modern Meson ────────────────────────────────────────────────────
# Ubuntu 22.04 ships Meson 0.61, but the pinned host-deps stack needs
# >= 1.3 (pixman 0.46). Install a current Meson via pip when the system
# one is too old. Newer releases (24.04+) already ship a new-enough Meson.
meson_version="$(meson --version 2>/dev/null || echo 0)"
meson_ok="no"
if command -v meson >/dev/null 2>&1; then
    meson_ok="$(awk -v v="$meson_version" 'BEGIN { split(v,a,"."); if (a[1] > 1 || (a[1] == 1 && a[2] >= 3)) print "yes"; else print "no" }')"
fi
if [[ "$meson_ok" != "yes" ]]; then
    playos_log_info "setup" "Meson $meson_version too old — installing current Meson via pip..."
    if [[ $EUID -eq 0 ]]; then
        python3 -m pip install --upgrade meson
    else
        sudo python3 -m pip install --upgrade meson
    fi
    playos_log_ok "setup" "Meson now: $(meson --version)"
fi

# ── Summary ────────────────────────────────────────────────────────
playos_log_step "Installation Summary"
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    playos_log_ok "setup" "Installed ${#INSTALLED[@]} package(s): ${INSTALLED[*]}"
fi
if [[ ${#ALREADY[@]} -gt 0 ]]; then
    playos_log_info "setup" "Already present: ${#ALREADY[@]} package(s)"
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
    playos_log_warn "setup" "Failed to install ${#FAILED[@]} package(s): ${FAILED[*]}"
fi

# ── Validate critical tools ────────────────────────────────────────
playos_log_step "Tool Validation"

CRITICAL_TOOLS=(
    "gcc:gcc"
    "make:make"
    "cmake:cmake"
    "qemu-system-x86_64:qemu-system-x86"
    "git:git"
    "python3:python3"
)

ALL_OK=true
for tool_pair in "${CRITICAL_TOOLS[@]}"; do
    binary="${tool_pair%%:*}"
    pkg="${tool_pair##*:}"
    if command -v "$binary" &>/dev/null; then
        playos_log_ok "validate" "$binary ($(command -v "$binary"))"
    else
        playos_log_error "validate" "$binary NOT FOUND (package: $pkg)"
        ALL_OK=false
    fi
done

# ── Check OVMF firmware ────────────────────────────────────────────
OVMF_CODE=""
for candidate in \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/edk2-ovmf/OVMF_CODE.fd \
    /usr/share/qemu/OVMF.fd; do
    if [[ -f "$candidate" ]]; then
        OVMF_CODE="$candidate"
        break
    fi
done

if [[ -n "$OVMF_CODE" ]]; then
    playos_log_ok "validate" "OVMF firmware: $OVMF_CODE"
else
    playos_log_warn "validate" "OVMF firmware not found at common paths — may need manual install"
fi

# ── Native Wayland/wlroots host dependencies ───────────────────────
playos_log_step "Native Wayland/wlroots host dependencies"
if [[ -x "$SCRIPT_DIR/build-host-deps.sh" ]]; then
    "$SCRIPT_DIR/build-host-deps.sh"
else
    playos_log_warn "setup" "build-host-deps.sh not found — run manually for native compositor builds"
fi

# ── Final result ───────────────────────────────────────────────────
if $ALL_OK; then
    playos_log_ok "setup" "Environment ready for PlayOS development."
    playos_log_info "setup" "Next: cd $(dirname "$REPO_ROOT")/playos-refdistro && make qemu-build"
else
    playos_log_error "setup" "Some tools are missing. Install them manually and re-run."
fi
