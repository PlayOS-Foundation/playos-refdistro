#!/bin/sh

profile_playos() {
    profile_standard

    # Multi-GPU initfs: amdgpu (AMD), nouveau (NVIDIA), plus USB
    # networking so netboot works on devices like the ROG Ally (USB-C dock NICs).
    initfs_features="$initfs_features network usbnet amdgpu amdgpu-firmware nvidia nvidia-firmware"

    title="PlayOS Reference OS"
    desc="Alpine-based PlayOS Runtime Device image"
    arch="x86_64"
    kernel_flavors="lts"
    hostname="playos"
    apkovl="genapkovl-playos.sh"

    # Multi-GPU kernel cmdline. amdgpu.sg_display=0 works around
    # Display Core hangs on ROG Ally (Phoenix APU / RDNA 3) — harmless on other GPUs.
    kernel_cmdline="console=tty0 amdgpu.sg_display=0 loglevel=7 ip=dhcp alpine_repo=http://192.168.0.196/playos/apks modloop=http://192.168.0.196/playos/modloop-lts apkovl=http://192.168.0.196/playos/playos.apkovl.tar.gz softlevel=playos-visual"
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
        raylib
        glfw

        # installer dependencies
        zstd
        sgdisk
        parted
        e2fsprogs
        util-linux
    "
}
