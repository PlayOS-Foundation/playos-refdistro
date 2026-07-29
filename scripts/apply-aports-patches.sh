#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-aports-patches.sh — Apply PlayOS patches to the Alpine aports tree
#
# Called from build-alpine-iso.sh after the aports repo is cloned/checked
# out.  Uses `git apply` so a mismatch is caught at build time instead of
# silently producing a broken ISO.
#
# Usage:
#   APPLY_APORTS_PATCHES_PATCHFILE=/path/to/patches/aports-mkimage.patch \
#     bash scripts/apply-aports-patches.sh /path/to/aports
#
# Environment:
#   APORTS_PATCHFILE   Path to the .patch file (default:
#                      $PLAYOS_ROOT/patches/aports-mkimage.patch)
# ---------------------------------------------------------------------------
set -euo pipefail

APORTS_DIR="${1:-}"
if [[ -z "$APORTS_DIR" ]]; then
    echo "ERROR: APORTS_DIR argument is required" >&2
    echo "Usage: apply-aports-patches.sh /path/to/aports" >&2
    exit 1
fi

if [[ ! -d "$APORTS_DIR/.git" ]]; then
    echo "ERROR: $APORTS_DIR is not a git repository" >&2
    echo "Clone aports before applying patches." >&2
    exit 1
fi

ROOT="${PLAYOS_ROOT:-${0%/*/*}}"
PATCHFILE="${APORTS_PATCHFILE:-$ROOT/patches/aports-mkimage.patch}"
APORTS_BRANCH="${APORTS_BRANCH:-3.24-stable}"

if [[ ! -f "$PATCHFILE" ]]; then
    echo "ERROR: Patch file not found: $PATCHFILE" >&2
    echo "Expected at: $ROOT/patches/aports-mkimage.patch" >&2
    exit 1
fi

echo "==> Applying PlayOS aports patches..."
echo "    Patch: $PATCHFILE"
echo "    Target: $APORTS_DIR"

# git apply requires the working tree to be clean.
cd "$APORTS_DIR"

if ! git diff --quiet 2>/dev/null; then
    echo "ERROR: aports working tree is dirty — cannot apply patches" >&2
    echo "This should not happen with a fresh clone.  Check $APORTS_DIR." >&2
    exit 1
fi

# Apply with --check first (dry-run) to get a clear failure message.
if ! git apply --check "$PATCHFILE" 2>&1; then
    echo "" >&2
    echo "===================================================================" >&2
    echo "FATAL: The PlayOS aports patch does NOT apply to the current" >&2
    echo "       Alpine aports source (branch $APORTS_BRANCH)." >&2
    echo "" >&2
    echo "This means Alpine has changed the scripts that PlayOS modifies." >&2
    echo "The patch must be regenerated against the updated source." >&2
    echo "" >&2
    echo "To fix:" >&2
    echo "  1. Read patches/README.md for the full regeneration procedure." >&2
    echo "  2. Regenerate patches/aports-mkimage.patch against the current" >&2
    echo "     aports source." >&2
    echo "  3. Commit the updated patch file and retry the build." >&2
    echo "===================================================================" >&2
    exit 1
fi

# Dry-run passed — apply for real.
git apply "$PATCHFILE"

echo "    ✅ Patches applied successfully."

# Quick smoke-test: verify the four changes took effect.
FAILED=0

if grep -q -- '--no-chown' scripts/mkimage.sh 2>/dev/null; then
    echo "    ❌ PATCH 1 verification failed: --no-chown still present in mkimage.sh" >&2
    FAILED=1
fi

if grep -q 'cp -Lrs' scripts/mkimage.sh 2>/dev/null; then
    echo "    ❌ PATCH 2 verification failed: cp -Lrs still present in mkimage.sh" >&2
    FAILED=1
fi

if ! grep -q 'playos-destdir-backup' scripts/mkimg.base.sh 2>/dev/null; then
    echo "    ❌ PATCH 3 verification failed: DESTDIR backup line not found in mkimg.base.sh" >&2
    FAILED=1
fi

if grep -q 'sd-mod\|usb-storage' scripts/mkimg.base.sh 2>/dev/null; then
    echo "    ❌ PATCH 4 verification failed: sd-mod/usb-storage still present in initfs_cmdline" >&2
    FAILED=1
fi

if [[ "$FAILED" -eq 1 ]]; then
    echo "" >&2
    echo "===================================================================" >&2
    echo "FATAL: Patch applied without error, but post-apply verification" >&2
    echo "       failed.  The patch content may be stale or incomplete." >&2
    echo "       Regenerate it following patches/README.md." >&2
    echo "===================================================================" >&2
    exit 1
fi

echo "    ✅ All four patch changes verified."
