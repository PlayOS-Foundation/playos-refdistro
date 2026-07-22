#!/bin/sh
set -eu

ALPINE_BRANCH="${PLAYOS_ALPINE_BRANCH:-v3.24}"

if [ "$ALPINE_BRANCH" = "edge" ]; then
    echo "error: unpinned Alpine edge environments are forbidden" >&2
    exit 1
fi

printf '%s\n'     "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main"     "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/community"     > /etc/apk/repositories

apk update
apk add --no-cache     abuild     alpine-base     alpine-conf     alpine-sdk     bash     build-base     ca-certificates     cmake     coreutils     dosfstools     e2fsprogs     git     grub     mtools     ninja     squashfs-tools     sudo     systemd-boot     syslinux     xorriso

update-ca-certificates
