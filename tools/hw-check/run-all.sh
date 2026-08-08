#!/bin/sh
# run-all.sh — Execute all hardware verification checks
#
# Runs check-display.sh, check-input.sh, check-audio.sh,
# check-storage.sh, and check-power.sh in sequence.
# Combined output goes to /run/playos/hw-check.log and stdout.
#
# Usage:
#   sh run-all.sh

set -e

HW_LOG="/run/playos/hw-check.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure log directory exists
mkdir -p /run/playos

# Clear previous log
: > "$HW_LOG"

echo "PlayOS Hardware Check — $(date)"
echo "============================================================"
echo ""

# Run each check
for check in display input audio storage power; do
    CHECK_SCRIPT="$SCRIPT_DIR/check-${check}.sh"
    if [ -x "$CHECK_SCRIPT" ]; then
        sh "$CHECK_SCRIPT" || true
    else
        echo "[SKIP] check-${check}.sh not found or not executable" | tee -a "$HW_LOG"
        echo ""
    fi
done

echo "============================================================"
echo "Hardware check complete."
echo "Full log: $HW_LOG"
