#!/bin/sh
# PlayOS production post-build lint (S12-T7)
#
# Buildroot post-build script — called with $1 = TARGET_DIR.
# Fails the build if any debug/remote-access artifact is present in the
# production image. The development image does not run this script.
#
# Forbidden artifacts:
#   busybox        interactive shell + applet toolbox
#   gdbserver      remote debugger
#   strace/ltrace  syscall tracers
#   evtest         input-event diagnostics
#   modetest       DRM/KMS diagnostics
#   dropbear       SSH daemon
#   ssh/sshd       any SSH client/server binary
#   tcpdump        packet capture
set -eu

TARGET_DIR="${1:?usage: post-build.sh TARGET_DIR}"

fail=0
check_absent() {
    name="$1"
    shift
    for path in "$@"; do
        if [ -e "${TARGET_DIR}${path}" ]; then
            echo "ERROR: production lint: forbidden artifact present: ${path} (${name})" >&2
            fail=1
        fi
    done
}

check_absent "busybox shell"     /bin/busybox /bin/sh
check_absent "gdbserver"        /usr/bin/gdbserver
check_absent "strace"           /usr/bin/strace
check_absent "ltrace"           /usr/bin/ltrace
check_absent "evtest"           /usr/bin/evtest
check_absent "modetest"         /usr/bin/modetest
check_absent "dropbear sshd"    /usr/sbin/dropbear /usr/bin/dropbear
check_absent "openssh server"   /usr/sbin/sshd /usr/bin/ssh /usr/bin/sshd
check_absent "tcpdump"          /usr/sbin/tcpdump /usr/bin/tcpdump

# Any file under /usr/bin or /usr/sbin that is a known debug helper.
for f in "${TARGET_DIR}/usr/bin"/* "${TARGET_DIR}/usr/sbin"/* \
         "${TARGET_DIR}/bin"/* "${TARGET_DIR}/sbin"/*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
        busybox|gdbserver|strace|ltrace|evtest|modetest|dropbear|sshd|ssh|tcpdump|stunnel|nc|ncat|socat)
            echo "ERROR: production lint: forbidden binary: /${f#"${TARGET_DIR}"/}" >&2
            fail=1
            ;;
    esac
done

if [ "$fail" -ne 0 ]; then
    echo "ERROR: production lint FAILED — debug artifacts present in production image" >&2
    exit 1
fi

echo "production lint: OK — no debug artifacts"
exit 0
