#!/bin/sh
# perf-baseline.sh — collect PlayOS performance baseline metrics (S14-T7)
#
# Usage:
#   On device:  sh scripts/perf-baseline.sh > perf-report.md
#   Via SSH:    ssh root@<ip> 'sh -s' < scripts/perf-baseline.sh > perf-report.md
set -eu

echo "# PlayOS Performance Baseline"
echo
echo "- Collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "- Host: $(uname -n) $(uname -r) $(uname -m)"
echo "- Model: $(cat /proc/device-tree/model 2>/dev/null || echo unknown)"
echo "- Uptime: $(awk '{print $1}' /proc/uptime) s"
echo

echo "## CPU"
echo
grep -m1 "model name" /proc/cpuinfo | sed 's/^[[:space:]]*//' | sed 's/^/    /'
echo "- Cores online: $(grep -c '^processor' /proc/cpuinfo)"
echo "- Loadavg: $(cat /proc/loadavg)"
echo

echo "## Memory"
echo
free -m | awk 'NR==1{print "    " $0} NR==2{printf "    %-10s %8sMB used %8sMB free %8sMB avail\n", $1, $3, $4, $7}'
echo

echo "## Thermal zones"
echo
if [ -d /sys/class/thermal ]; then
    for z in /sys/class/thermal/thermal_zone*; do
        [ -e "$z/temp" ] || continue
        t=$(awk '{print $1/1000}' "$z/temp" 2>/dev/null)
        typ=$(cat "$z/type" 2>/dev/null || echo unknown)
        echo "- $typ: ${t}C"
    done
else
    echo "- no thermal zones found"
fi
echo

echo "## Power supply"
echo
for s in /sys/class/power_supply/*; do
    name=$(basename "$s")
    status=$(cat "$s/status" 2>/dev/null || echo unknown)
    cap=$(cat "$s/capacity" 2>/dev/null || echo "?")
    echo "- $name: status=$status capacity=$cap%"
done
echo

echo "## Shell FPS (last log lines)"
echo
grep -h -i "fps" /data/log/* 2>/dev/null | tail -3 | sed 's/^/    /' || true
echo

echo "## Init boot markers"
echo
grep -E "playos-init starting|system ready" /data/log/init.log 2>/dev/null | tail -4 | sed 's/^/    /' || true
echo
