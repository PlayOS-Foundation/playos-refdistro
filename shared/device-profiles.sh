#!/usr/bin/env bash
# device-profiles.sh — Deploy device profiles to the rootfs.
#
# Usage:
#   deploy_device_profiles ROOTFS_DIR [REFDEV_SRC_DIR]
#
# Copies .toml profiles from playos-reference-devices into /etc/playos/device-profiles/.

set -euo pipefail

deploy_device_profiles() {
    local MNT="${1:?}"
    local REFDEV_DIR="${2:-/mnt/playos-reference-devices}"

    log_step "Deploying device profiles"

    mkdir -p "$MNT/etc/playos/device-profiles"

    if [ ! -d "$REFDEV_DIR" ]; then
        log_info "No reference-devices directory found — skipping"
        return 0
    fi

    local count=0
    for profile in "$REFDEV_DIR"/*/device-profile.toml; do
        if [ -f "$profile" ]; then
            local name
            name="$(basename "$(dirname "$profile")")"
            cp "$profile" "$MNT/etc/playos/device-profiles/${name}.toml"
            log_info "$name profile installed"
            count=$((count + 1))
        fi
    done

    if [ "$count" -eq 0 ]; then
        echo "    No device profiles found in $REFDEV_DIR"
    fi
}
