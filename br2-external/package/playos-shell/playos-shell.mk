################################################################################
# playos-shell — Sprint 5.5
#
# Controller-first PlayOS shell running as a Wayland client against
# playos-compositor. Renders through vendored Raylib 6.0 (PLATFORM_PLAYOS
# backend in external/raylib/src/platforms/rcore_playos.c), which drives
# EGL/GLES2 via a fullscreen xdg_toplevel + wl_egl_window.
################################################################################

PLAYOS_SHELL_VERSION = 0.1.0
PLAYOS_SHELL_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-shell
PLAYOS_SHELL_SITE_METHOD = local
PLAYOS_SHELL_DEPENDENCIES = wayland wayland-protocols mesa3d playos-platform-api playos-runtime
PLAYOS_SHELL_INSTALL_STAGING = NO

PLAYOS_SHELL_CONF_OPTS = \
	-DCMAKE_C_STANDARD=99 \
	-DPLAYOS_SHELL_USE_RAYLIB=ON \
	-DPLAYOS_RUNTIME_DIR=$(STAGING_DIR)/usr

$(eval $(cmake-package))
