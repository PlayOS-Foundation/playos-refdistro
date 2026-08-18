################################################################################
# playos-installer — PlayOS trusted internal-disk installer
#
# Raylib Wayland client that repartitions the target fixed disk (the non-USB
# NVMe drive) and installs the system payload carried on the installer USB's
# playos-a partition (/rootfs.squashfs + /BOOTX64.EFI). Registered as a shell
# so it takes over the compositor surface while the one-shot install runs.
#
# Uses libfdisk for GPT partition writing and calls mkfs.fat/mkfs.ext4 via
# system(), so util-linux (libfdisk + blockdev/mkfs), dosfstools and
# e2fsprogs are required at runtime. efibootmgr is a best-effort NVRAM entry.
################################################################################

PLAYOS_INSTALLER_VERSION = 0.1.0
PLAYOS_INSTALLER_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-installer
PLAYOS_INSTALLER_SITE_METHOD = local
PLAYOS_INSTALLER_DEPENDENCIES = wayland wayland-protocols mesa3d playos-platform-api \
	playos-runtime playos-raylib util-linux dosfstools e2fsprogs efibootmgr
PLAYOS_INSTALLER_INSTALL_STAGING = NO

PLAYOS_INSTALLER_CONF_OPTS = \
	-DCMAKE_C_STANDARD=99

$(eval $(cmake-package))
