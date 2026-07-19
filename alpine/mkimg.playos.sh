#!/bin/sh

profile_playos() {
    profile_standard

    # Include USB ethernet + full network drivers so netboot works
    # on devices like the ROG Ally (USB-C dock NICs).
    initfs_features="$initfs_features network usbnet"

    title="PlayOS Reference OS"
    desc="Alpine-based PlayOS Runtime Device image"
    arch="x86_64"
    kernel_flavors="lts"
    hostname="playos"
    apkovl="genapkovl-playos.sh"

    # Start the visual runlevel after sysinit/boot. Keep a serial console for
    # headless Ubuntu Server and PXE bring-up. Early DRM/KMS remains enabled.
    kernel_cmdline="console=tty0 nomodeset modprobe.blacklist=amdgpu loglevel=7 ip=dhcp alpine_repo=http://192.168.0.196/playos/apks modloop=http://192.168.0.196/playos/modloop-lts apkovl=http://192.168.0.196/playos/playos.apkovl.tar.gz softlevel=playos-visual"
    syslinux_serial="0 115200"

    apks="$apks
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
        openrc
        pipewire
        seatd
        seatd-openrc
        wayland
        wireplumber
        wireplumber-openrc
        wlroots0.19
    "
}
