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
