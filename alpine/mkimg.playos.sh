#!/bin/sh

profile_playos() {
    profile_standard

    title="PlayOS Reference OS"
    desc="Alpine-based PlayOS Runtime Device image"
    arch="x86_64"
    kernel_flavors="lts"
    hostname="playos"
    apkovl="genapkovl-playos.sh"

    # Start the visual runlevel after sysinit/boot. Keep a serial console for
    # headless Ubuntu Server and PXE bring-up. Early DRM/KMS remains enabled.
    kernel_cmdline="quiet modules=loop,squashfs,sd-mod,usb-storage console=tty0 console=ttyS0,115200 softlevel=playos-visual"
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
        openssh-openrc
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
