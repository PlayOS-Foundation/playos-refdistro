#!/usr/bin/env bash
# verify-versions.sh — Fail if any required pin in versions.lock is empty or
# inconsistent with the defconfigs.
#
# Usage: bash scripts/verify-versions.sh [path/to/versions.lock]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${1:-$REPO_ROOT/versions.lock}"

if [[ ! -f "$LOCK" ]]; then
    echo "ERROR: versions.lock not found at $LOCK" >&2
    exit 1
fi

get_pin() {
    grep -E "^${1}=" "$LOCK" | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | xargs
}

# Pins that MUST be present for a reproducible build.
REQUIRED=(
    BUILDROOT_COMMIT
    LINUX_VERSION
    LINUX_SHA256
    PLAYOS_SPEC_COMMIT
    PLAYOS_PLATFORM_API_COMMIT
    PLAYOS_RUNTIME_COMMIT
    PLAYOS_INIT_COMMIT
    PLAYOS_COMPOSITOR_COMMIT
    PLAYOS_SHELL_COMMIT
    RAYLIB_COMMIT
)

missing=()
for key in "${REQUIRED[@]}"; do
    value="$(get_pin "$key")"
    if [[ -z "$value" ]]; then
        missing+=("$key")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: The following required pins are empty in $LOCK:" >&2
    for key in "${missing[@]}"; do
        echo "  - $key" >&2
    done
    echo "Fill them before building. See versions.lock for guidance." >&2
    exit 1
fi

# Cross-check the pinned kernel version against the defconfigs.
LINUX_VERSION="$(get_pin LINUX_VERSION)"
for defconfig in \
    "$REPO_ROOT/br2-external/configs/playos_ally_defconfig" \
    "$REPO_ROOT/br2-external/configs/playos_qemu_x86_64_defconfig"; do
    if [[ ! -f "$defconfig" ]]; then
        continue
    fi
    cfg_ver="$(grep -E '^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=' "$defconfig" | head -1 | cut -d= -f2- | tr -d '"' | xargs)"
    if [[ -n "$cfg_ver" && "$cfg_ver" != "$LINUX_VERSION" ]]; then
        echo "ERROR: $defconfig pins kernel $cfg_ver but versions.lock LINUX_VERSION=$LINUX_VERSION" >&2
        exit 1
    fi
done

echo "OK: all required version pins are set and consistent."
