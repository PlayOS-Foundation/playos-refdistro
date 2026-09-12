#!/bin/sh
# mvp-smoke.sh — collect on-device evidence for the automatable MVP criteria (S14-T5)
#
# Usage:
#   On device:  sh scripts/mvp-smoke.sh > mvp-evidence.md
#   Via SSH:    ssh root@<ip> 'sh -s' < scripts/mvp-smoke.sh > mvp-evidence.md
#
# The interactive criteria (1, 5, 7, 10-14, 16, 19) still need a human at the
# device; this script captures the machine-checkable half and the log evidence
# that backs the rest. Note the Ally has no battery-backed RTC, so `date` is
# meaningless until NTP runs — treat /data/log timestamps as uptime-relative.
set -u

hdr() {
    echo
    echo "## $1"
    echo
}

echo "# PlayOS MVP smoke evidence"
echo
echo "- Collected: $(date -u +%Y-%m-%dT%H:%M:%SZ) (device clock — may be unset)"
echo "- Host: $(uname -n) | kernel $(uname -r) $(uname -m)"
echo "- Uptime: $(awk '{print $1}' /proc/uptime) s"
echo "- Kernel cmdline: $(cat /proc/cmdline)"

hdr "Build identity"
for f in /init /usr/bin/playos-shell /usr/bin/playos-compositor \
         /usr/bin/playos-overlay /usr/lib/libplayos.so.0.3.0; do
    if [ -f "$f" ]; then
        printf '    %s  %8s bytes  %s\n' \
            "$(sha256sum "$f" 2>/dev/null | cut -c1-16)" \
            "$(ls -l "$f" | awk '{print $5}')" "$f"
    fi
done

hdr "Criterion 1/2 — UEFI boot + EFI artifact"
echo "    ESP: $(mount | grep -m1 ' /EFI ' || echo 'not mounted')"
for p in /EFI/EFI/BOOT/BOOTX64.EFI /EFI/BOOT/BOOTX64.EFI; do
    [ -f "$p" ] && echo "    FOUND $p ($(ls -l "$p" | awk '{print $5}') bytes)"
done
echo "    boot.json: $(tr -d '\n' < /EFI/playos/boot.json 2>/dev/null || echo 'missing')"

hdr "Criterion 3 — PID 1 is playos-init"
echo "    comm        : $(cat /proc/1/comm 2>/dev/null)"
echo "    exe         : $(readlink /proc/1/exe 2>/dev/null)"
echo "    /sbin/init  : $(readlink /sbin/init 2>/dev/null || echo '(not a symlink)')"
echo "    /init size  : $(ls -l /init 2>/dev/null | awk '{print $5}') bytes"
echo "    marker      : $(strings /init 2>/dev/null | grep -m1 -i 'playos-init')"

hdr "Criterion 4 — compositor owns DRM/KMS + Wayland"
pgrep -a -f playos-compositor | sed 's/^/    /' || echo "    NOT RUNNING"
ls -l /run/playos/playos-0 2>/dev/null | sed 's/^/    /' || echo "    no wayland socket"

hdr "Criterion 5 — shell process"
pgrep -a playos-shell | sed 's/^/    /' || echo "    NOT RUNNING"
grep -a "fps" /data/log/shell-stderr.log 2>/dev/null | tail -2 | sed 's/^/    /'

hdr "Criterion 6/12 — GPU: DRM nodes, kernel driver, renderer"
ls -l /dev/dri/ 2>/dev/null | sed 's/^/    /' || echo "    no /dev/dri"
echo "    drivers: $(cat /sys/class/drm/card0/device/uevent 2>/dev/null | grep -m1 DRIVER || echo unknown)"
grep -a -i -E "EGL vendor|EGL driver name|GL renderer|renderer.c" \
     /data/log/compositor-stderr.log 2>/dev/null | tail -4 | cut -c1-130 | sed 's/^/    /'
grep -a -i -E "amdgpu|radeon|mesa" /data/log/init.log 2>/dev/null | tail -3 | sed 's/^/    /'

hdr "Criterion 8 — shell links the public libplayos ABI"
ls -l /usr/lib/libplayos.so* 2>/dev/null | sed 's/^/    /'
shelpid=$(pgrep -x playos-shell | head -1)
if [ -n "${shelpid:-}" ]; then
    grep -m2 libplayos "/proc/$shelpid/maps" 2>/dev/null | sed 's/^/    /'
fi
grep -m1 "PLAYOS_API" /usr/include/playos/playos.h 2>/dev/null | sed 's/^/    /'

hdr "Criterion 9 — trusted sockets only"
ls -l /run/playos/*.sock 2>/dev/null | sed 's/^/    /' || echo "    no sockets"

hdr "Criterion 10/13/14 — supervision, background/resume"
grep -a -E "spawning game|game spawned|game .* exited|TerminateGame|backgrounded|SIGSTOP|foreground" \
     /data/log/init.log 2>/dev/null | tail -12 | sed 's/^/    /'
echo "    --- compositor state transitions ---"
grep -a "foreground" /data/log/compositor-stderr.log 2>/dev/null | tail -6 | sed 's/^/    /'

hdr "Criterion 11/12 — gesture + capture evidence"
grep -a -E "screenshot requested|screenshot -> |ARMOURY CRATE tap|screencopy" \
     /data/log/shell-stderr.log 2>/dev/null | tail -6 | sed 's/^/    /'

hdr "Criterion 15 — ALSA devices"
aplay -l 2>/dev/null | sed 's/^/    /' || echo "    aplay not available"
grep -a -i "audio" /data/log/shell-stderr.log 2>/dev/null | tail -3 | sed 's/^/    /'

hdr "Criterion 16 — crash handling"
grep -a -E "exited: code=|crashed|restarting" /data/log/init.log 2>/dev/null | tail -6 | sed 's/^/    /'

hdr "Criterion 17 — /data is ext4, separate, persistent"
mount | grep " /data " | sed 's/^/    /' || echo "    /data not mounted"
ls /data 2>/dev/null | tr '\n' ' ' | sed 's/^/    dirs: /'
echo
ls -la /data/saves 2>/dev/null | tail -3 | sed 's/^/    /'
cat /data/playos-boot.txt 2>/dev/null | tail -2 | sed 's/^/    /'

hdr "Criterion 18 — system image immutable"
mount | grep " on / " | sed 's/^/    /' || echo "    root mount not found"

hdr "Criterion 19 — recovery without accelerated graphics"
echo "    recovery marker in logs:"
grep -a -i -E "recovery" /data/log/init.log 2>/dev/null | tail -4 | sed 's/^/        /' || echo "        none"
echo "    software render path available? (SimpleDRM/modesetting utilities)"
found=0
for b in modetest weston kmscube playos-recovery; do
    if command -v "$b" >/dev/null 2>&1; then
        echo "        FOUND $b"; found=1
    fi
done
[ "$found" = 0 ] && echo "        none — recovery renders through the compositor (SimpleDRM path still TODO: S14-T6 gap, F3)"
