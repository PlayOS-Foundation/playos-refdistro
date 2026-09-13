################################################################################
# playos-recovery — GL-free recovery UI (Sprint 14, F3)
#
# A minimal Wayland client that paints the recovery menu into a wl_shm buffer
# and rasterises its text in software with stb_truetype. It needs no GL/EGL and
# no GPU, so it is the recovery UI for the case where the accelerated stack is
# what broke: the compositor can come up in software (pixman/SimplEDRM) but
# playos-shell cannot, because it is a GL client. Actions go through the trusted
# IPC to playos-init (reboot/shutdown/rollback/factory reset).
################################################################################

PLAYOS_RECOVERY_VERSION = 0.1.0
PLAYOS_RECOVERY_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-recovery
PLAYOS_RECOVERY_SITE_METHOD = local
PLAYOS_RECOVERY_DEPENDENCIES = wayland wayland-protocols playos-runtime
PLAYOS_RECOVERY_INSTALL_STAGING = NO

PLAYOS_RECOVERY_CONF_OPTS = \
	-DCMAKE_C_STANDARD=99

$(eval $(cmake-package))
