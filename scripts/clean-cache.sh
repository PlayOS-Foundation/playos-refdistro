#!/usr/bin/env bash
# clean-cache.sh — Clean PlayOS build caches without removing the Alpine minirootfs.
#
# Default:    remove ccache, CMake build dirs, and APK cache inside the nspawn root.
# --full:     also remove the entire .build/ directory (Alpine minirootfs included).
# --dry-run:  show what would be removed without deleting.
#
# Usage:
#   bash scripts/clean-cache.sh              # targeted cleanup
#   bash scripts/clean-cache.sh --full       # nuke everything including minirootfs
#   bash scripts/clean-cache.sh --dry-run    # preview only

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
NSPAWN_ROOT="$BUILD_DIR/alpine-rootfs"
FULL=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --full)   FULL=true ;;
        --dry-run) DRY_RUN=true ;;
        *)
            echo "Usage: $0 [--full] [--dry-run]" >&2
            exit 2
            ;;
    esac
done

remove() {
    local path="$1"
    if [ ! -e "$path" ]; then
        echo "  (not present) $path"
        return
    fi
    local size
    size=$(du -sh "$path" 2>/dev/null | cut -f1)
    if $DRY_RUN; then
        echo "  [dry-run] would remove $path ($size)"
    else
        sudo rm -rf "$path"
        echo "  removed $path ($size)"
    fi
}

echo "=== PlayOS cache cleanup ==="
if $DRY_RUN; then
    echo "(dry-run — nothing will be deleted)"
fi
echo ""

if $FULL; then
    echo "Full cleanup: removing entire .build/ directory"
    echo "  (includes Alpine minirootfs — next build will re-download)"
    echo ""
    remove "$BUILD_DIR"
else
    echo "Targeted cleanup: removing build caches inside nspawn root"
    echo "  (Alpine minirootfs preserved — setup-ubuntu-build-host.sh not needed)"
    echo ""

    remove "$NSPAWN_ROOT/var/tmp/playos-build"
    remove "$NSPAWN_ROOT/var/cache/ccache"
    remove "$NSPAWN_ROOT/var/cache/apk"
fi

echo ""
echo "Done."
