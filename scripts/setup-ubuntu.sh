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

# ── Required packages ──────────────────────────────────────────────
PACKAGES=(
    # Core build tools
    build-essential gcc g++ make cmake ninja-build
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
)

playos_log_info "setup" "Updating package lists..."
apt-get update -qq

INSTALLED=()
ALREADY=()
FAILED=()

for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
        ALREADY+=("$pkg")
    else
        playos_log_info "setup" "Installing $pkg..."
        if apt-get install -y -qq "$pkg" 2>/dev/null; then
            INSTALLED+=("$pkg")
        else
            FAILED+=("$pkg")
        fi
    fi
done

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

# ── Final result ───────────────────────────────────────────────────
if $ALL_OK; then
    playos_log_ok "setup" "Environment ready for PlayOS development."
    playos_log_info "setup" "Next: cd $(dirname "$REPO_ROOT")/playos-refdistro && make qemu-build"
else
    playos_log_error "setup" "Some tools are missing. Install them manually and re-run."
fi
