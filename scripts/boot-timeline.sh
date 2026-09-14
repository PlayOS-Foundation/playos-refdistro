#!/bin/sh
# boot-timeline.sh — stage-by-stage timeline of the most recent boot.
#
# Two sources, because the boot has two halves:
#
#  1. /data/log/boot-marks.log — the S14-P1 early markers. Written by *both*
#     inits (the initramfs one included) to /dev/kmsg plus a tmpfs file that
#     survives the pivot, then persisted to /data once /data exists. This is the
#     only view of the phase before the pivot: the persistent log below does not
#     exist until /data is mounted, which is why 2.7 s of a 6.5 s boot used to be
#     unattributable.
#  2. /data/log/init.log — the persistent log (last boot only).
#
# Usage:
#   scripts/boot-timeline.sh [initlog] [markslog]
#   ssh root@device 'sh -s' < scripts/boot-timeline.sh
#
# Works with busybox awk/sh (no gawk extensions).

INITLOG=${1:-/data/log/init.log}
MARKSLOG=${2:-/data/log/boot-marks.log}

show_marks() {
    if [ ! -r "$MARKSLOG" ]; then
        echo "  (no $MARKSLOG — image predates the S14-P1 markers)"
        return
    fi
    awk '
        {
            if (match($0, /\[ *[0-9]+\.[0-9]+\]/)) {
                t = substr($0, RSTART + 1, RLENGTH - 2) + 0
                msg = substr($0, RSTART + RLENGTH)
                sub(/^ +/, "", msg)
                printf "%7.3fs  %+8.3fs  %s\n", t, t - prev, msg
                prev = t
            }
        }
    ' "$MARKSLOG"
}

show_persistent() {
    if [ ! -r "$INITLOG" ]; then
        echo "  (cannot read $INITLOG)"
        return
    fi
    tr -d '\0' < "$INITLOG" | awk '
        /playos-init starting as PID 1/ { first = NR }
        { line[NR] = $0 }
        END {
            if (first == 0) { print "  (no boot marker found)"; exit }
            prev = 0
            for (i = first; i <= NR; i++) {
                l = line[i]
                if (match(l, /\[ *[0-9]+\.[0-9]+\]/)) {
                    t = substr(l, RSTART + 1, RLENGTH - 2) + 0
                    msg = l
                    sub(/^\[[^]]*\] */, "", msg)
                    sub(/^\[[^]]*\] */, "", msg)
                    printf "%7.3fs  %+8.3fs  %s\n", t, t - prev, msg
                    prev = t
                }
            }
        }
    '
}

echo "uptime   delta      event"
echo "──────   ────────   ──────────────────────────────────────────────────────"
echo "-- boot marks (S14-P1: covers the initramfs phase and the pivot) --"
show_marks
echo
echo "-- persistent init log (last boot) --"
show_persistent
