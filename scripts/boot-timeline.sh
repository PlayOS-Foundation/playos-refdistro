#!/bin/sh
# boot-timeline.sh — print the stage-by-stage timeline of the most recent boot.
#
# init writes its persistent log to /data/log/init.log with timestamps in
# seconds since power-on, appending across boots. This extracts the last boot
# and prints each line with the delta since the previous one, which is how the
# P1 (cold boot < 5s) work attributes where the time actually goes.
#
# Usage:
#   scripts/boot-timeline.sh [logfile]        # default /data/log/init.log
#   ssh root@device 'sh -s' < scripts/boot-timeline.sh
#
# Works with busybox awk/sh (no gawk extensions).

LOG=${1:-/data/log/init.log}

if [ ! -r "$LOG" ]; then
    echo "boot-timeline: cannot read $LOG" >&2
    exit 1
fi

tr -d '\0' < "$LOG" | awk '
    /playos-init starting as PID 1/ { first = NR }
    { line[NR] = $0 }
    END {
        if (first == 0) { print "boot-timeline: no boot marker found"; exit 1 }

        printf "%-9s %-9s %s\n", "uptime", "delta", "event"
        prev = 0
        for (i = first; i <= NR; i++) {
            l = line[i]
            if (match(l, /\[ *[0-9]+\.[0-9]+\]/)) {
                t = substr(l, RSTART + 1, RLENGTH - 2) + 0
                # drop the "[ time] [tag ] " prefix from the message
                msg = l
                sub(/^\[[^]]*\] */, "", msg)
                sub(/^\[[^]]*\] */, "", msg)
                printf "%7.3fs  %+8.3fs  %s\n", t, t - prev, msg
                prev = t
            } else if (length(l) > 0) {
                printf "%9s %9s  %s\n", "", "", l
            }
        }
    }
'
