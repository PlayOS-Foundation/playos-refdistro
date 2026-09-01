#!/bin/sh
# mvp-smoke.sh — collect on-device evidence for automatable MVP criteria (S14-T5)
#
# Usage:
#   On device:  sh scripts/mvp-smoke.sh > mvp-evidence.md
#   Via SSH:    ssh root@<ip> 'sh -s' < scripts/mvp-smoke.sh > mvp-evidence.md
set -eu

echo "# PlayOS MVP smoke evidence"
echo
echo "- Collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "- Host: $(uname -n) $(uname -r) $(uname -m)"
echo

echo "## Criterion 3 — PID 1"
echo
echo "- $(awk '{print $4}' /proc/1/comm 2>/dev/null || echo 'unknown')"
echo

echo "## Criterion 4 — compositor + Wayland socket"
echo
pgrep -a -f "playos-compositor" | sed 's/^/    /' || echo "- NOT RUNNING"
ls -l /run/playos/playos-0 2>/dev/null | sed 's/^/    /' || echo "- no wayland socket"
echo

echo "## Criterion 5 — shell process"
echo
pgrep -a playos-shell | sed 's/^/    /' || echo "- NOT RUNNING"
echo

echo "## Criterion 6/12 — DRM/GPU"
echo
ls -l /dev/dri/ 2>/dev/null | sed 's/^/    /' || echo "- no /dev/dri"
grep -h -E "AMDGPU|Radeon|mesa|iris|i915" /data/log/init.log 2>/dev/null | tail -4 | sed 's/^/    /' || true
echo

echo "## Criterion 8 — libplayos linkage"
echo
ldd /usr/bin/playos-shell 2>/dev/null | grep -E "playos|raylib" | sed 's/^/    /' || echo "- shell not found"
echo

echo "## Criterion 15 — ALSA devices"
echo
aplay -l 2>/dev/null | sed 's/^/    /' || echo "- aplay not found"
echo

echo "## Criterion 17 — /data ext4"
echo
mount | grep " /data " | sed 's/^/    /' || echo "- /data not mounted"
echo

echo "## Criterion 18 — root immutable squashfs"
echo
mount | grep " on / " | sed 's/^/    /' || echo "- root mount not found"
echo

echo "## Control sockets (criterion 9)"
echo
ls -l /run/playos/*.sock 2>/dev/null | sed 's/^/    /' || echo "- no sockets"
echo
