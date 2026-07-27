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
coreutils
dbus
dbus-openrc
e2fsprogs-extra
eudev
eudev-openrc
gptfdisk
iwd
iwd-openrc
kmod
libdrm
libinput
libxkbcommon
linux-firmware-amdgpu
linux-firmware-nvidia
linux-firmware-intel
linux-firmware-mediatek
wireless-regdb
mesa-dri-gallium
mesa-egl
mesa-gbm
mesa-gles
mesa-vulkan-ati
mesa-vulkan-nouveau
mesa-vulkan-intel
networkmanager
networkmanager-cli
networkmanager-tui
networkmanager-openrc
networkmanager-wifi
openssh
openrc
parted
pipewire
seatd
seatd-openrc
sgdisk
wayland
wireplumber
wireplumber-openrc
wlroots0.19
systemd-boot
efibootmgr
zstd
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

# The PlayOS critical path.
rc_add dbus playos-visual
rc_add seatd playos-visual
rc_add playos-compositor playos-visual

# WiFi backend — iwd for NetworkManager (iwd is lighter and doesn't
# need a separate OpenRC wpa_supplicant service).
rc_add networkmanager playos-visual
rc_add iwd playos-visual

# NetworkManager configuration: auto-connect wired interfaces, manage WiFi via iwd.
mkdir -p "$tmp/etc/NetworkManager/conf.d"
makefile root:root 0644 "$tmp/etc/NetworkManager/conf.d/playos.conf" <<'EOF'
[main]
plugins=keyfile
dhcp=internal

[device]
wifi.backend=iwd
wifi.iwd.autoconnect=yes

[connectivity]
enabled=false
EOF

# Default wired connection profile — auto-connects ANY ethernet device (eth0, enx*, enp*, usb*, ...)
mkdir -p "$tmp/etc/NetworkManager/system-connections"
makefile root:root 0600 "$tmp/etc/NetworkManager/system-connections/00-wired-dhcp.nmconnection" <<'EOF'
[connection]
id=wired-dhcp
type=ethernet
autoconnect=true
autoconnect-priority=100

[ipv4]
method=auto

[ipv6]
method=auto
EOF

# SSH debug access — use host key or env var, fallback to debug key.
mkdir -p "$tmp/root/.ssh"
SSH_PUBKEY=""
if [ -n "${PLAYOS_SSH_PUBKEY:-}" ]; then
    SSH_PUBKEY="$PLAYOS_SSH_PUBKEY"
elif [ -f "${HOME}/.ssh/id_ed25519.pub" ]; then
    SSH_PUBKEY="$(cat "${HOME}/.ssh/id_ed25519.pub")"
elif [ -f "${HOME}/.ssh/id_rsa.pub" ]; then
    SSH_PUBKEY="$(cat "${HOME}/.ssh/id_rsa.pub")"
else
    SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKjUiS/ZaOaGpyGkzotL9kUnsqOTpN07h0nZBpPwsDbP playos-debug"
fi
echo "$SSH_PUBKEY" > "$tmp/root/.ssh/authorized_keys"
chown root:root "$tmp/root/.ssh/authorized_keys"
chmod 0600 "$tmp/root/.ssh/authorized_keys"
rc_add sshd playos-visual

# Include the compositor init script and binaries in the overlay.
if [ -f /etc/init.d/playos-compositor ]; then
    mkdir -p "$tmp/etc/init.d"
    cp /etc/init.d/playos-compositor "$tmp/etc/init.d/playos-compositor"
    chmod 0755 "$tmp/etc/init.d/playos-compositor"
fi
if [ -f /usr/bin/playos-compositor ]; then
    mkdir -p "$tmp/usr/bin"
    cp /usr/bin/playos-compositor "$tmp/usr/bin/playos-compositor"
    chmod 0755 "$tmp/usr/bin/playos-compositor"
fi
if [ -f /usr/bin/playos-shell ]; then
    mkdir -p "$tmp/usr/bin"
    cp /usr/bin/playos-shell "$tmp/usr/bin/playos-shell"
    chmod 0755 "$tmp/usr/bin/playos-shell"
    # Bundle raylib + glfw shared libraries (shell links against them at runtime).
    mkdir -p "$tmp/usr/lib"
    if [ -f /usr/lib/libraylib.so.600 ]; then
        cp /usr/lib/libraylib.so.600 "$tmp/usr/lib/"
        ln -sf libraylib.so.600 "$tmp/usr/lib/libraylib.so"
    fi
    if [ -f /usr/lib/libglfw.so.3 ]; then
        cp /usr/lib/libglfw.so.3 "$tmp/usr/lib/"
    fi
fi
# Installer is now integrated into playos-shell (dd-based pipeline).
# The standalone playos-installer-gui and playos-installer shell script have been retired.

# Bundle pre-built samples (hello-playos, space-invaders, input-debug) so they
# are available on first boot without manual deployment.
SAMPLES_DIR="/workspace/.build/samples-out"
if [ -d "$SAMPLES_DIR" ] && [ -f "$SAMPLES_DIR/hello-playos" ]; then
    echo "==> Bundling PlayOS samples"
    mkdir -p "$tmp/playos-samples/build"
    cp "$SAMPLES_DIR/hello-playos"   "$tmp/playos-samples/build/hello-playos"
    cp "$SAMPLES_DIR/space-invaders" "$tmp/playos-samples/build/space-invaders"
    cp "$SAMPLES_DIR/input-debug"    "$tmp/playos-samples/build/input-debug"
    chmod 0755 "$tmp/playos-samples/build/hello-playos"
    chmod 0755 "$tmp/playos-samples/build/space-invaders"
    chmod 0755 "$tmp/playos-samples/build/input-debug"
fi

# The disk image is bundled as a separate file on the ISO (not inside
# the apkovl) to keep the apkovl small, avoiding xorriso large-file issues.
echo "==> Disk image is placed alongside the apkovl on the ISO (not bundled inside apkovl)"

mkdir -p "$tmp/etc/runlevels/playos-async"

tar -c -C "$tmp" etc usr root playos-samples 2>/dev/null | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
