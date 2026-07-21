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
gptfdisk
iwd
libdrm
libinput
libxkbcommon
linux-firmware-amdgpu
linux-firmware-nvidia
linux-firmware-intel
mesa-dri-gallium
mesa-egl
mesa-gbm
mesa-gles
mesa-vulkan-ati
mesa-vulkan-nouveau
mesa-vulkan-intel
networkmanager
networkmanager-openrc
openssh
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

# The PlayOS critical path.
rc_add dbus playos-visual
rc_add seatd playos-visual
rc_add playos-compositor playos-visual

# SSH debug access — pre-configured key so we can debug the compositor.
mkdir -p "$tmp/root/.ssh"
makefile root:root 0600 "$tmp/root/.ssh/authorized_keys" <<EOF
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKjUiS/ZaOaGpyGkzotL9kUnsqOTpN07h0nZBpPwsDbP playos-debug
EOF
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
    if [ -f /usr/lib/libraylib.so.450 ]; then
        cp /usr/lib/libraylib.so.450 "$tmp/usr/lib/"
        ln -sf libraylib.so.450 "$tmp/usr/lib/libraylib.so"
    fi
    if [ -f /usr/lib/libglfw.so.3 ]; then
        cp /usr/lib/libglfw.so.3 "$tmp/usr/lib/"
    fi
fi
# Standalone installer GUI app (spawned by shell overlay).
if [ -f /usr/bin/playos-installer-gui ]; then
    cp /usr/bin/playos-installer-gui "$tmp/usr/bin/playos-installer-gui"
    chmod 0755 "$tmp/usr/bin/playos-installer-gui"
fi
# Standalone installer shell script (called by the GUI).
if [ -f /usr/bin/playos-installer ]; then
    cp /usr/bin/playos-installer "$tmp/usr/bin/playos-installer"
    chmod 0755 "$tmp/usr/bin/playos-installer"
fi

# Bundle pre-built samples (hello-playos, space-invaders) so they
# are available on first boot without manual deployment.
SAMPLES_DIR="/workspace/.build/samples-out"
if [ -d "$SAMPLES_DIR" ] && [ -f "$SAMPLES_DIR/hello-playos" ]; then
    echo "==> Bundling PlayOS samples"
    mkdir -p "$tmp/playos-samples/build"
    cp "$SAMPLES_DIR/hello-playos"   "$tmp/playos-samples/build/hello-playos"
    cp "$SAMPLES_DIR/space-invaders" "$tmp/playos-samples/build/space-invaders"
    chmod 0755 "$tmp/playos-samples/build/hello-playos"
    chmod 0755 "$tmp/playos-samples/build/space-invaders"
fi

# Bundle the pre-built disk image so the installer can find it at
# /usr/share/playos/playos-gpt-*.img.zst on the live ISO.
IMAGE_FILE=$(echo /workspace/out/playos-gpt-*.img.zst 2>/dev/null | head -1)
if [ -n "$IMAGE_FILE" ] && [ -f "$IMAGE_FILE" ]; then
    echo "==> Bundling disk image: $(basename "$IMAGE_FILE")"
    mkdir -p "$tmp/usr/share/playos"
    cp "$IMAGE_FILE" "$tmp/usr/share/playos/$(basename "$IMAGE_FILE")"
    chmod 0644 "$tmp/usr/share/playos/$(basename "$IMAGE_FILE")"
fi

mkdir -p "$tmp/etc/runlevels/playos-async"

tar -c -C "$tmp" etc usr root playos-samples 2>/dev/null | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
