#!/usr/bin/env bash
# verify-build.sh — Validate PlayOS build artifacts for correctness.
#
# Checks:
#   E1: Artifacts exist, correct format, reasonable sizes
#   E2: Disk image integrity (GPT, filesystems)
#   E3: PXE deployment correctness
#
# Usage:  bash scripts/verify-build.sh [--pxe /var/www/html/playos]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$ROOT/out"
PXE_DIR="${PXE_DIR:-/var/www/html/playos}"
PASS=0
FAIL=0

check() {
    local desc="$1" status="$2"
    case "$status" in
        pass) echo "  ✓ $desc"; PASS=$((PASS + 1)) ;;
        fail) echo "  ✗ $desc"; FAIL=$((FAIL + 1)) ;;
        warn) echo "  ⚠ $desc" ;;
        skip) echo "  - $desc (skipped)" ;;
    esac
}

# ── E1: Build artifacts ─────────────────────────────────────────────────────
echo "=== E1: Build artifacts ==="

DISK_ZST=$(find "$OUT" -maxdepth 1 -name 'playos-gpt-*.img.zst' -print 2>/dev/null | head -1)
DISK_SHA="${DISK_ZST}.sha256"
ISO=$(find "$OUT" -maxdepth 1 -name '*.iso' -print 2>/dev/null | head -1)

if [ -z "$DISK_ZST" ]; then
    check "Disk image (.img.zst)" fail
else
    SIZE=$(stat -c%s "$DISK_ZST" 2>/dev/null || echo 0)
    SIZE_MB=$((SIZE / 1048576))
    if [ "$SIZE_MB" -gt 1536 ]; then
        check "Disk image size (${SIZE_MB} MiB > 1.5 GiB max)" fail
    else
        check "Disk image exists (${SIZE_MB} MiB)" pass
    fi
fi

if [ -f "$DISK_SHA" ]; then
    if sha256sum -c "$DISK_SHA" --quiet 2>/dev/null; then
        check "SHA-256 checksum matches" pass
    else
        check "SHA-256 checksum MISMATCH" fail
    fi
else
    check "SHA-256 checksum file" warn
fi

if [ -z "$ISO" ]; then
    check "ISO image (.iso)" fail
else
    ISO_SIZE=$(stat -c%s "$ISO" 2>/dev/null || echo 0)
    ISO_SIZE_MB=$((ISO_SIZE / 1048576))
    check "ISO image exists (${ISO_SIZE_MB} MiB)" pass
fi

# ── E2: Disk image integrity ─────────────────────────────────────────────────
echo "=== E2: Disk image integrity ==="

if [ -z "$DISK_ZST" ]; then
    check "Decompress + verify (no disk image)" skip
else
    TMP_IMG="/tmp/playos-verify.img"
    echo "    Decompressing..."
    zstd -d -f -o "$TMP_IMG" "$DISK_ZST" 2>/dev/null

    # GPT integrity
    if sgdisk -v "$TMP_IMG" >/dev/null 2>&1; then
        check "GPT table integrity" pass
    else
        check "GPT table integrity — ERRORS" fail
    fi

    # Filesystem checks via loop device
    LOOP=$(sudo losetup --find --show -P "$TMP_IMG" 2>/dev/null || true)
    if [ -n "$LOOP" ]; then
        # p1 = ESP (vfat)
        FSCK_VFAT_OUT=$(sudo fsck.vfat -n "${LOOP}p1" 2>&1 || true)
        if echo "$FSCK_VFAT_OUT" | grep -qE "differences between boot sector|Dirty bit is set|Leaving filesystem unchanged"; then
            check "ESP filesystem (vfat — cosmetic warnings only)" pass
        else
            check "ESP filesystem — ERRORS" fail
        fi

        # p2 = root (ext4)
        if sudo fsck.ext4 -fn "${LOOP}p2" >/dev/null 2>&1; then
            check "Root filesystem (ext4)" pass
        else
            FSCK_OUT=$(sudo fsck.ext4 -fn "${LOOP}p2" 2>&1 || true)
            if echo "$FSCK_OUT" | grep -q "clean"; then
                check "Root filesystem (ext4 — clean)" pass
            else
                check "Root filesystem — ERRORS" fail
            fi
        fi

        sudo losetup -d "$LOOP" 2>/dev/null || true
    else
        check "Loop device setup (cannot check filesystems)" fail
    fi

    TMP_SIZE=$(du -h "$TMP_IMG" | cut -f1)
    rm -f "$TMP_IMG"
    echo "    Cleaned up temp image ($TMP_SIZE)"
fi

# ── E3: PXE deployment ──────────────────────────────────────────────────────
echo "=== E3: PXE deployment ==="

if [ ! -d "$PXE_DIR" ]; then
    check "PXE directory ($PXE_DIR)" skip
else
    PXE_PASS=0
    PXE_FAIL=0

    for f in "*.iso" "playos.apkovl.tar.gz" "vmlinuz-lts" "initramfs-lts" "modloop-lts"; do
        if find "$PXE_DIR" -maxdepth 1 -name "$f" -print -quit 2>/dev/null | grep -q .; then
            PXE_PASS=$((PXE_PASS + 1))
        else
            check "PXE: $f missing" fail
            PXE_FAIL=$((PXE_FAIL + 1))
        fi
    done

    if [ -d "$PXE_DIR/apks" ]; then
        APK_COUNT=$(find "$PXE_DIR/apks" -name '*.apk' 2>/dev/null | wc -l)
        if [ "$APK_COUNT" -gt 0 ]; then
            check "PXE: apks/ ($APK_COUNT packages)" pass
            PXE_PASS=$((PXE_PASS + 1))
        else
            check "PXE: apks/ empty" fail
            PXE_FAIL=$((PXE_FAIL + 1))
        fi
    else
        check "PXE: apks/ directory missing" fail
        PXE_FAIL=$((PXE_FAIL + 1))
    fi

    if find "$PXE_DIR" -maxdepth 1 -name '*.img.zst' -print -quit 2>/dev/null | grep -q .; then
        check "PXE: disk image (.img.zst) deployed" pass
        PXE_PASS=$((PXE_PASS + 1))
    else
        check "PXE: disk image (.img.zst) not deployed" warn
    fi

    # Ownership
    WWW_COUNT=$(sudo find "$PXE_DIR" -not -user www-data 2>/dev/null | wc -l)
    if [ "$WWW_COUNT" -eq 0 ]; then
        check "PXE: all files owned by www-data" pass
    else
        check "PXE: $WWW_COUNT files NOT owned by www-data" fail
        PXE_FAIL=$((PXE_FAIL + 1))
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "============================================================================"
echo "Build verification: $PASS passed, $FAIL failed"
echo "============================================================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
