#!/bin/sh
# check-power.sh — Verify battery, AC, and thermal reporting
#
# Checks:
#   - /sys/class/power_supply/ exposes battery and AC state
#   - /sys/class/thermal/ exposes thermal zones
#   - CPU frequency scaling (amd-pstate)
#
# Output format: [OK] / [FAIL] / [SKIP] <message>

HW_LOG="/run/playos/hw-check.log"
mkdir -p /run/playos

log() { echo "$@" | tee -a "$HW_LOG"; }

log "=== POWER ==="

# Check power supply devices
PSU_COUNT=0
BATTERY_FOUND=0
AC_FOUND=0

for psu in /sys/class/power_supply/*; do
    if [ ! -d "$psu" ]; then break; fi
    PSU_COUNT=$((PSU_COUNT + 1))

    PSU_NAME=$(basename "$psu")
    PSU_TYPE=$(cat "$psu/type" 2>/dev/null || echo "Unknown")

    log "[OK]  Power supply: $PSU_NAME (type: $PSU_TYPE)"

    case "$PSU_TYPE" in
        Battery)
            BATTERY_FOUND=$((BATTERY_FOUND + 1))
            CAPACITY=$(cat "$psu/capacity" 2>/dev/null || echo "?")
            STATUS=$(cat "$psu/status" 2>/dev/null || echo "?")
            HEALTH=$(cat "$psu/health" 2>/dev/null || echo "?")
            log "      Capacity: ${CAPACITY}%  Status: $STATUS  Health: $HEALTH"
            ;;
        Mains)
            AC_FOUND=$((AC_FOUND + 1))
            ONLINE=$(cat "$psu/online" 2>/dev/null || echo "?")
            log "      Online: $ONLINE"
            ;;
        USB)
            log "      USB power source"
            ;;
    esac
done

if [ "$BATTERY_FOUND" -eq 0 ]; then
    log "[WARN] No battery power supply found"
else
    log "[OK]  Battery reporting working ($BATTERY_FOUND device(s))"
fi

if [ "$AC_FOUND" -eq 0 ]; then
    log "[INFO] No AC adapter power supply found"
else
    log "[OK]  AC adapter reporting working ($AC_FOUND device(s))"
fi

echo ""

log "=== THERMAL ==="

# Check thermal zones
TZ_COUNT=0
for tz in /sys/class/thermal/thermal_zone*; do
    if [ ! -d "$tz" ]; then break; fi
    TZ_COUNT=$((TZ_COUNT + 1))

    TZ_TYPE=$(cat "$tz/type" 2>/dev/null || echo "unknown")
    TZ_TEMP=$(cat "$tz/temp" 2>/dev/null || echo "?")
    # Temperature is in millidegrees C — convert to degrees
    if [ "$TZ_TEMP" != "?" ]; then
        TZ_TEMP_C=$((TZ_TEMP / 1000))
    else
        TZ_TEMP_C="?"
    fi

    log "[OK]  Zone $(basename "$tz"): type=$TZ_TYPE  temp=${TZ_TEMP_C}°C"
done

if [ "$TZ_COUNT" -eq 0 ]; then
    log "[WARN] No thermal zones found"
else
    log "[OK]  Found $TZ_COUNT thermal zone(s)"
fi

echo ""

log "=== CPU FREQUENCY ==="

# Check CPU frequency scaling driver
SCALING_DRIVER=""
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]; then
    SCALING_DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)
    log "[OK]  Scaling driver: $SCALING_DRIVER"
    
    CUR_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "?")
    MAX_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "?")
    log "      Current freq: ${CUR_FREQ} kHz  Max: ${MAX_FREQ} kHz"
else
    log "[INFO] CPU frequency scaling not exposed via sysfs"
fi

# Check for amd-pstate
if echo "$SCALING_DRIVER" | grep -q "amd"; then
    log "[OK]  AMD P-State driver active"
else
    log "[INFO] Scaling driver is not AMD P-State: ${SCALING_DRIVER:-unknown}"
fi

echo ""
