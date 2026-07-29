#!/bin/sh -eu

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
e2fsprogs
e2fsprogs-extra
efibootmgr
eudev
eudev-openrc
glfw
gptfdisk
iwd
iwd-openrc
kmod
libdrm
libinput
libxkbcommon
linux-firmware-amdgpu
linux-firmware-ath10k
linux-firmware-ath11k
linux-firmware-brcm
linux-firmware-intel
linux-firmware-mediatek
linux-firmware-nvidia
mesa-dri-gallium
mesa-egl
mesa-gbm
mesa-gles
mesa-vulkan-ati
mesa-vulkan-intel
mesa-vulkan-nouveau
networkmanager
networkmanager-cli
networkmanager-openrc
networkmanager-tui
networkmanager-wifi
openssh
openrc
parted
pipewire
seatd
seatd-openrc
sgdisk
systemd-boot
util-linux
wayland
wireplumber
wireplumber-openrc
wireless-regdb
wlroots0.19
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

# The PlayOS critical path — visual runlevel: GPU → seat → compositor → shell.
# No networking or background services here (first-frame rule).
rc_add dbus playos-visual
rc_add seatd playos-visual
rc_add playos-compositor playos-visual

# Gate: activates playos-async after compositor signals readiness.
rc_add playos-async-trigger playos-visual

# WiFi backend — iwd for NetworkManager (iwd is lighter and doesn't
# need a separate OpenRC wpa_supplicant service).
# These run in playos-async, started only after compositor signals
# /run/playos-visual-ready, so they don't compete with first frame.
rc_add networkmanager playos-async
rc_add iwd playos-async

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
rc_add sshd playos-async

# WiFi auto-connect profile (baked into LiveUSB for headless/PXE debugging)
mkdir -p "$tmp/etc/NetworkManager/system-connections"
if [ -n "${PLAYOS_WIFI_SSID:-}" ] && [ -n "${PLAYOS_WIFI_PSK:-}" ]; then
    echo "==> Baking WiFi auto-connect profile into apkovl: $PLAYOS_WIFI_SSID"
    cat > "$tmp/etc/NetworkManager/system-connections/01-wifi-auto.nmconnection" <<WIFIEOF
[connection]
id=${PLAYOS_WIFI_SSID}
type=wifi
autoconnect=true
autoconnect-priority=50

[wifi]
ssid=${PLAYOS_WIFI_SSID}
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=${PLAYOS_WIFI_PSK}

[ipv4]
method=auto
WIFIEOF
    chown root:root "$tmp/etc/NetworkManager/system-connections/01-wifi-auto.nmconnection"
    chmod 0600 "$tmp/etc/NetworkManager/system-connections/01-wifi-auto.nmconnection"
fi

# Include the compositor init script and binaries in the overlay.
if [ -f /etc/init.d/playos-compositor ]; then
    mkdir -p "$tmp/etc/init.d"
    cp /etc/init.d/playos-compositor "$tmp/etc/init.d/playos-compositor"
    chmod 0755 "$tmp/etc/init.d/playos-compositor"
fi
# Include the async trigger init script (gates playos-async runlevel).
if [ -f /etc/init.d/playos-async-trigger ]; then
    mkdir -p "$tmp/etc/init.d"
    cp /etc/init.d/playos-async-trigger "$tmp/etc/init.d/playos-async-trigger"
    chmod 0755 "$tmp/etc/init.d/playos-async-trigger"
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

# Build the apkovl archive from the overlay tree.
# Each top-level directory is optional — only include what exists to avoid
# silent failures when components (samples, etc.) weren't built.
echo "==> Building apkovl overlay archive"
OVERLAY_DIRS=""
for dir in etc root usr playos-samples; do
    if [ -d "$tmp/$dir" ]; then
        OVERLAY_DIRS="$OVERLAY_DIRS $dir"
    else
        echo "    Note: $dir overlay directory not present — skipping"
    fi
done

if [ -z "$OVERLAY_DIRS" ]; then
    echo "ERROR: No overlay directories found — nothing to archive" >&2
    exit 1
fi

tar -c -C "$tmp" $OVERLAY_DIRS | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
echo "    apkovl: $HOSTNAME.apkovl.tar.gz ($(du -h "$HOSTNAME.apkovl.tar.gz" | cut -f1))"
