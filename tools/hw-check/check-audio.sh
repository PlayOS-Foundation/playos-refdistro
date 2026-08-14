#!/bin/sh
# check-audio.sh — Verify audio hardware and playback
#
# Checks:
#   - Sound cards visible via /proc/asound
#   - aplay -l lists devices
#   - Short playback test (if aplay available)
#
# Output format: [OK] / [FAIL] / [SKIP] <message>

HW_LOG="/run/playos/hw-check.log"
mkdir -p /run/playos

log() { echo "$@" | tee -a "$HW_LOG"; }

log "=== AUDIO ==="

# Check /proc/asound
if [ -d /proc/asound ]; then
    CARD_COUNT=$(ls -d /proc/asound/card* 2>/dev/null | wc -l)
    if [ "$CARD_COUNT" -gt 0 ]; then
        log "[OK]  $CARD_COUNT sound card(s) detected:"
        for card in /proc/asound/card*; do
            if [ -d "$card" ]; then
                CARD_ID=$(cat "$card/id" 2>/dev/null || echo "unknown")
                log "      $(basename "$card"): $CARD_ID"
            fi
        done
    else
        log "[FAIL] /proc/asound exists but no sound cards found"
    fi
else
    log "[FAIL] /proc/asound not found — no ALSA sound subsystem"
fi

# Check for HDA Intel devices
if [ -d /sys/class/sound ]; then
    for dev in /sys/class/sound/card*; do
        if [ -d "$dev" ]; then
            CARD_NUM=$(basename "$dev" | sed 's/card//')
            if [ -r "$dev/id" ]; then
                CARD_NAME=$(cat "$dev/id" 2>/dev/null)
                log "[OK]  Sound card $CARD_NUM: $CARD_NAME"
            fi
        fi
    done
fi

# aplay device listing
if command -v aplay >/dev/null 2>&1; then
    log "[INFO] aplay device list:"
    aplay -l 2>&1 | while IFS= read -r line; do
        log "      $line"
    done
else
    log "[SKIP] aplay not available — install alsa-utils for playback testing"
fi

# CS35L41 amp binding — the internal-speaker amps must bind AND register an
# interrupt, otherwise the ALC294 exposes no analog PCM and `default` playback
# silently produces nothing from the Ally speakers.
if [ -d /sys/bus/acpi/devices/CSC3551:00 ]; then
    CSC_DRIVER=$(grep -m1 '^DRIVER=' /sys/bus/acpi/devices/CSC3551:00/uevent 2>/dev/null | cut -d= -f2-)
    log "[INFO] CSC3551:00 ACPI node present (driver: ${CSC_DRIVER:-none})"
else
    log "[FAIL] ACPI node CSC3551:00 not found — amps not enumerated"
fi

CS35L41_I2C_FOUND=0
for dev in /sys/bus/i2c/devices/*/; do
    uevent="$dev/uevent"
    [ -r "$uevent" ] || continue
    if grep -qi 'cs35l41' "$uevent"; then
        CS35L41_I2C_FOUND=1
        DEV=$(basename "$dev")
        DRV=$(grep -m1 '^DRIVER=' "$uevent" | cut -d= -f2-)
        if [ -n "$DRV" ]; then
            log "[OK]  CS35L41 I2C client $DEV bound to $DRV"
        else
            log "[FAIL] CS35L41 I2C client $DEV has no driver bound"
        fi
    fi
done
if [ "$CS35L41_I2C_FOUND" -eq 0 ]; then
    log "[FAIL] No CS35L41 I2C client found on /sys/bus/i2c/devices"
fi

# The decisive check: the amp IRQ must be registered. On the Ally the amp IRQ
# is a GpioInt on the AMD GPIO controller (pinctrl-amd); if that controller is
# missing, this line is absent and the speakers stay silent.
if grep -Ei 'cs35l41|CSC3551' /proc/interrupts 2>/dev/null | grep -q .; then
    log "[OK]  CS35L41 interrupt registered:"
    grep -Ei 'cs35l41|CSC3551' /proc/interrupts 2>/dev/null | while IFS= read -r line; do
        log "      $line"
    done
else
    log "[FAIL] No CS35L41 interrupt in /proc/interrupts (amp IRQ not wired)"
fi

# Short playback test — generate a 440 Hz sine tone if speaker-test is available
if command -v speaker-test >/dev/null 2>&1; then
    log "[INFO] Running short playback test (440 Hz, 1 second)..."
    if speaker-test -t sine -f 440 -l 1 -r 48000 -D default 2>/dev/null; then
        log "[OK]  Playback test succeeded"
    else
        log "[FAIL] Playback test failed"
    fi
elif command -v aplay >/dev/null 2>&1; then
    # Generate a minimal WAV file using printf
    WAV="/tmp/playos-test-tone.wav"
    if command -v dd >/dev/null 2>&1; then
        # Generate a 0.5s 440Hz test tone (simplified)
        log "[INFO] Generating test tone..."
        dd if=/dev/zero bs=44 count=1 of="$WAV" 2>/dev/null
        printf 'RIFF\x24\x00\x08\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00data\x00\x00\x08\x00' > "$WAV"
        if aplay -q "$WAV" 2>/dev/null; then
            log "[OK]  Basic playback test sent"
        fi
        rm -f "$WAV"
    fi
fi

echo ""
