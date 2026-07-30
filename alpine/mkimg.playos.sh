#!/bin/sh

profile_playos() {
    profile_standard

    # Disable modloop signing — we sign packages, not the initramfs.
    modloop_sign=no

    # Multi-GPU initfs: amdgpu (AMD), nouveau (NVIDIA), plus USB
    # networking so netboot works on devices like the ROG Ally (USB-C dock NICs).
    initfs_features="$initfs_features network usbnet amdgpu amdgpu-firmware nvidia nvidia-firmware"

    title="PlayOS Reference OS"
    desc="Alpine-based PlayOS Runtime Device image"
    arch="x86_64"
    kernel_flavors="stable"
    hostname="playos"
    apkovl="genapkovl-playos.sh"

    # Kernel cmdline. amdgpu.sg_display=0 works around Display Core hangs
    # on ROG Ally (Phoenix APU / RDNA 3) — harmless on other GPUs.
    # PXE-specific params (ip=dhcp, alpine_repo, modloop, apkovl) belong
    # in the PXE server boot config, not the ISO — the ISO must boot from USB.
    # cfg80211.ieee80211_regdom=GR: default world regdomain (00) disables
    # EU channels 12/13 and most 5GHz — APs on those channels are invisible
    # to scans. GR is the reference-device country.
    kernel_cmdline="console=tty0 amdgpu.sg_display=0 loglevel=7 cfg80211.ieee80211_regdom=GR softlevel=playos-visual"
    syslinux_serial="0 115200"

    # xtables-addons-stable doesn't exist in Alpine 3.24 (only -lts is built).
    # PlayOS doesn't need advanced netfilter modules — basic kernel
    # netfilter is sufficient. Clear the kernel_addons inherited from
    # profile_standard to prevent xtables-addons-${flavor} from being added.
    kernel_addons=""

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
        foot
        font-dejavu
        gptfdisk
        iwd
        iwd-openrc
        kmod
        libdrm
        libinput
        libxkbcommon
        linux-firmware-amdgpu
        linux-firmware-nvidia
        linux-firmware-rtl_nic
        linux-firmware-intel
        linux-firmware-ath10k
        linux-firmware-ath11k
        linux-firmware-brcm
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
        glfw
        e2fsprogs
        util-linux
    "
}
