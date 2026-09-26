################################################################################
# playos-lvgl — LVGL v9 as a shared library
#
# Promotes the vendored LVGL in playos-shell/external/lvgl into a package so the
# shell and the overlay (playos-overlay) link one copy. Wrapper project mirrors
# playos-raylib.
################################################################################

PLAYOS_LVGL_VERSION = 9.5.0
PLAYOS_LVGL_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-lvgl
PLAYOS_LVGL_SITE_METHOD = local
PLAYOS_LVGL_INSTALL_STAGING = YES
PLAYOS_LVGL_CONF_OPTS = \
	-DPLAYOS_LVGL_SOURCE_DIR=$(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-shell/external/lvgl

$(eval $(cmake-package))
