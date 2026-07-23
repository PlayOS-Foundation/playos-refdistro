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

    # Kernel cmdline. amdgpu.sg_display=0 works around Display Core hangs
    # on ROG Ally (Phoenix APU / RDNA 3) — harmless on other GPUs.
    # PXE-specific params (ip=dhcp, alpine_repo, modloop, apkovl) belong
    # in the PXE server boot config, not the ISO — the ISO must boot from USB.
    kernel_cmdline="console=tty0 amdgpu.sg_display=0 loglevel=7 softlevel=playos-visual"
    syslinux_serial="0 115200"

    apks="$apks
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
        libdrm
        libinput
        libxkbcommon
        linux-firmware-amdgpu
        linux-firmware-nvidia
        linux-firmware-intel
        linux-firmware-mediatek
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
        raylib
        glfw
        e2fsprogs
        util-linux
    "
}
