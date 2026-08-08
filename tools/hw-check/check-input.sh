#!/bin/sh
# check-input.sh — Verify controller input devices
#
# Checks:
#   - /dev/input/event* nodes exist
#   - At least one device has gamepad/joystick capabilities
#   - Optionally reads a few events to confirm activity
#
# Output format: [OK] / [FAIL] / [SKIP] <message>

HW_LOG="/run/playos/hw-check.log"
mkdir -p /run/playos

log() { echo "$@" | tee -a "$HW_LOG"; }

log "=== INPUT ==="

# Find input devices
EVENT_COUNT=0
JOYSTICK_FOUND=0

for event in /dev/input/event*; do
    if [ ! -e "$event" ]; then
        break
    fi
    EVENT_COUNT=$((EVENT_COUNT + 1))

    EVENT_NAME=$(basename "$event")
    DEV_NAME=""

    # Read device name from sysfs
    if [ -r "/sys/class/input/$EVENT_NAME/device/name" ]; then
        DEV_NAME=$(cat "/sys/class/input/$EVENT_NAME/device/name" 2>/dev/null)
    fi

    log "[OK]  Input device: $event — $DEV_NAME"

    # Check for joystick/gamepad capability
    if [ -r "/sys/class/input/$EVENT_NAME/device/capabilities/abs" ]; then
        log "      Has absolute axes — possible controller"
        JOYSTICK_FOUND=$((JOYSTICK_FOUND + 1))
    fi

    # Check for evdev key bits (buttons)
    if [ -r "/sys/class/input/$EVENT_NAME/device/capabilities/key" ]; then
        log "      Has key/button capability"
    fi
done

if [ "$EVENT_COUNT" -eq 0 ]; then
    log "[FAIL] No input event devices found"
elif [ "$JOYSTICK_FOUND" -eq 0 ]; then
    log "[WARN] No devices with absolute axes found — controller may not be detected"
else
    log "[OK]  Found $JOYSTICK_FOUND device(s) with controller capabilities"
    log "[OK]  Total $EVENT_COUNT input event device(s)"
fi

# Quick event check: read 2 seconds of events from each device
if command -v timeout >/dev/null 2>&1; then
    log "[INFO] Sampling input events for 2 seconds (press buttons to verify)..."
    for event in /dev/input/event*; do
        if [ ! -e "$event" ]; then break; fi
        EVENT_NAME=$(basename "$event")
        # Use dd to read events non-blocking for 2 seconds
        DATA=$(timeout 2 dd if="$event" bs=24 count=1 2>/dev/null | od -An -tx1 2>/dev/null | head -1)
        if [ -n "$DATA" ]; then
            log "[OK]  $event receives events"
        fi
    done
fi

echo ""
