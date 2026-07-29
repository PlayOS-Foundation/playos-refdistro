#!/usr/bin/env bash
# verify-sibling-repos.sh — Check that PlayOS sibling repos exist before building.
#
# Usage:
#   verify_sibling_repos RUNTIME_SRC SHELL_SRC PLATFORM_SRC SAMPLES_SRC [REFDEV_SRC]

set -euo pipefail

verify_sibling_repos() {
    local RUNTIME_SRC="${1:?}"
    local SHELL_SRC="${2:?}"
    local PLATFORM_SRC="${3:?}"
    local SAMPLES_SRC="${4:?}"
    local REFDEV_SRC="${5:-}"

    log_step "Verifying sibling repositories"

    for repo_var in RUNTIME_SRC SHELL_SRC PLATFORM_SRC SAMPLES_SRC; do
        local repo_path
        repo_path="${!repo_var}"
        if [ ! -d "$repo_path" ]; then
            log_error "$repo_var=$repo_path does not exist"
            echo "Clone it alongside this repo or set $repo_var to the correct path." >&2
            exit 1
        fi
        if [ ! -f "$repo_path/CMakeLists.txt" ]; then
            log_error "$repo_var=$repo_path is missing CMakeLists.txt — is this the right repo?"
            exit 1
        fi
        log_info "$repo_var: $repo_path"
    done

    # Optional: reference devices repo
    if [ -n "$REFDEV_SRC" ] && [ -d "$REFDEV_SRC" ]; then
        log_info "REFDEV_SRC: $REFDEV_SRC"
    fi
}
