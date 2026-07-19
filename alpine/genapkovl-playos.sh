#!/bin/sh -e

HOSTNAME="${1:-playos}"
tmp="$(mktemp -d)"

cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT

makefile() {
    owner="$1"
    perms="$2"
    filename="$3"
    cat > "$filename"
    chown "$owner" "$filename"
    chmod "$perms" "$filename"
}

rc_add() {
    mkdir -p "$tmp/etc/runlevels/$2"
    ln -sf "/etc/init.d/$1" "$tmp/etc/runlevels/$2/$1"
}

mkdir -p "$tmp/etc/apk" "$tmp/etc/conf.d" "$tmp/etc/runlevels"
makefile root:root 0644 "$tmp/etc/hostname" <<EOF
$HOSTNAME
EOF

makefile root:root 0644 "$tmp/etc/apk/world" <<'EOF'
alpine-base
alpine-conf
bluez
bluez-openrc
dbus
dbus-openrc
eudev
eudev-openrc
iwd
libdrm
libinput
libxkbcommon
linux-firmware-amdgpu
mesa-dri-gallium
mesa-egl
mesa-gbm
mesa-gles
mesa-vulkan-ati
networkmanager
networkmanager-openrc
openssh
openssh-openrc
openrc
pipewire
seatd
seatd-openrc
wayland
wireplumber
wireplumber-openrc
wlroots0.19
EOF

# Alpine base boot services.
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add udev sysinit
rc_add udev-trigger sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

# The PlayOS critical path. The compositor service is added when musl-built
# PlayOS APKs are introduced; until then this profile proves Alpine boot,
# device discovery, firmware, graphics packages, and seat access.
rc_add dbus playos-visual
rc_add seatd playos-visual

mkdir -p "$tmp/etc/runlevels/playos-async"

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
