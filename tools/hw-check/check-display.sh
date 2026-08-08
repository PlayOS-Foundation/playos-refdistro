#!/bin/sh
# check-display.sh — Verify DRM/KMS display and render nodes
#
# Checks:
#   - /dev/dri/card* exists and can be inspected
#   - /dev/dri/renderD* exists
#
# Output format: [OK] / [FAIL] / [SKIP] <message>

HW_LOG="/run/playos/hw-check.log"
mkdir -p /run/playos

log() { echo "$@" | tee -a "$HW_LOG"; }

log "=== DISPLAY ==="

# Check DRM card nodes
CARD_COUNT=0
for card in /dev/dri/card*; do
    if [ -e "$card" ]; then
        CARD_COUNT=$((CARD_COUNT + 1))
        log "[OK]  DRM card node: $card"
        # Try to get driver info
        if [ -r "/sys/class/drm/$(basename "$card")/device/vendor" ]; then
            VENDOR=$(cat "/sys/class/drm/$(basename "$card")/device/vendor" 2>/dev/null || echo "unknown")
            DEVICE=$(cat "/sys/class/drm/$(basename "$card")/device/device" 2>/dev/null || echo "unknown")
            log "      Vendor: $VENDOR  Device: $DEVICE"
        fi
    fi
done

if [ "$CARD_COUNT" -eq 0 ]; then
    log "[FAIL] No DRM card nodes found"
else
    log "[OK]  Found $CARD_COUNT DRM card node(s)"
fi

# Check render nodes
RENDER_COUNT=0
for render in /dev/dri/renderD*; do
    if [ -e "$render" ]; then
        RENDER_COUNT=$((RENDER_COUNT + 1))
        log "[OK]  Render node: $render"
    fi
done

if [ "$RENDER_COUNT" -eq 0 ]; then
    log "[FAIL] No render nodes found"
else
    log "[OK]  Found $RENDER_COUNT render node(s)"
fi

# Check framebuffer
if [ -e /dev/fb0 ]; then
    log "[OK]  Framebuffer /dev/fb0 exists"
else
    log "[INFO] No framebuffer device (/dev/fb0) — DRM-only path"
fi

echo ""
