################################################################################
# playos-overlay — PlayOS trusted in-game overlay
#
# Raylib client running against playos-compositor via the playos_overlay_v1
# Wayland interface. Pre-spawned by playos-init and hidden; the compositor
# maps/unmaps it when the user presses the reserved SYSTEM button. Control
# requests (dismiss / terminate game) go over the protocol and the trusted
# /run/playos/control.sock socket respectively.
################################################################################

PLAYOS_OVERLAY_VERSION = 0.1.0
PLAYOS_OVERLAY_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-overlay
PLAYOS_OVERLAY_SITE_METHOD = local
PLAYOS_OVERLAY_DEPENDENCIES = wayland wayland-protocols mesa3d playos-platform-api playos-runtime playos-raylib
PLAYOS_OVERLAY_INSTALL_STAGING = NO

PLAYOS_OVERLAY_CONF_OPTS = \
	-DCMAKE_C_STANDARD=99

$(eval $(cmake-package))
