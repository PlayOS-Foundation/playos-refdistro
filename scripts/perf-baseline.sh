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

echo "## Shell FPS (last log lines — S14 P4: idle is now a few fps, not ~55)"
echo
grep -h -i "fps" /data/log/shell-stderr.log 2>/dev/null | tail -3 | sed 's/^/    /' || true
echo
echo "## Per-role frame rate from the compositor (S14 P2)"
echo "    'game=' is the in-game instrumentation: the compositor counts every"
echo "    committed client frame, so it covers non-cooperative games too."
grep -h -a "fps shell=" /data/log/compositor-stderr.log 2>/dev/null | tail -6 | sed 's/^/    /' || true
printf "    in-game peak: "
grep -h -a "fps shell=" /data/log/compositor-stderr.log 2>/dev/null \
    | sed -n 's/.*game=\([0-9]*\).*/\1/p' | sort -n | tail -1 \
    | awk '{ print ($1 == "" ? "(no game ran)" : $1 " commits/s") }'
echo

echo "## Boot markers (timestamps are seconds since power-on)"
echo
grep -a -E "playos-init starting as PID 1|system ready|ShellReady" \
     /data/log/init.log 2>/dev/null | tail -3 | sed 's/^/    /' || true
echo

# ── Log-derived latencies ──────────────────────────────────────────────────
# Every init.log line is prefixed with "[ <seconds>]" of system uptime, so the
# sprint's latency targets can be read straight out of the log without extra
# instrumentation. Each measurement prints the last completed pair.
log_delta() {
    pat_a="$1"
    pat_b="$2"
    label="$3"
    awk -v a="$pat_a" -v b="$pat_b" -v lbl="$label" '
        {
            t = -1
            if (match($0, /\[[ ]*[0-9]+\.[0-9]+\]/)) {
                s = substr($0, RSTART + 1, RLENGTH - 2)
                gsub(/ /, "", s)
                t = s + 0
            }
            if ($0 ~ a) last = t
            if ($0 ~ b && last != -1) { printf "    %-34s %.3f s\n", lbl, t - last; last = -1 }
        }' /data/log/init.log 2>/dev/null | tail -1
}

echo "## Latencies (log-derived)"
echo
log_delta "received type=LaunchGame"      "GAME_FOREGROUND"   "launch→game foreground"
log_delta "received type=ShowOverlay"     "PLAYOS_UI_FOREGROUND" "ARMOURY→overlay (IPC)"
log_delta "TerminateGame: pid"            "SHELL_FOREGROUND"  "game exit→shell"
echo "    boot: init starts at $(grep -a -m1 'playos-init starting' /data/log/init.log | sed 's/.*\[ *\([0-9.]*\)\].*/\1/') s (kernel+firmware before init)"
echo

echo "## Idle CPU (5 s sample, % of one core)"
echo
for p in playos-shell playos-compositor playos-overlay; do
    pid=$(pgrep -f "$p" | head -1)
    [ -n "$pid" ] || continue
    a=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
    sleep 5
    b=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
    [ -n "$a" ] && echo "    $p (pid $pid): $(( (b - a) * 100 / 500 ))%"
done
echo

echo "## Direct scanout"
echo
n=$(grep -a -c -i "scanout" /data/log/compositor-stderr.log 2>/dev/null || true)
if [ "${n:-0}" -gt 0 ]; then
    grep -a -i "scanout" /data/log/compositor-stderr.log | tail -3 | sed 's/^/    /'
else
    echo "    no 'scanout' lines at the default wlroots log level — not confirmable from logs alone"
fi
echo
