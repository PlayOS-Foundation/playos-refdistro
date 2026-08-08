################################################################################
# playos-compositor — wlroots-based Wayland compositor (Sprint 2)
################################################################################

PLAYOS_COMPOSITOR_VERSION = 0.2.0
PLAYOS_COMPOSITOR_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-compositor
PLAYOS_COMPOSITOR_SITE_METHOD = local
PLAYOS_COMPOSITOR_DEPENDENCIES = wlroots wayland wayland-protocols libxkbcommon pixman
PLAYOS_COMPOSITOR_INSTALL_STAGING = NO

# Generated protocol source from playos-runtime is needed
PLAYOS_COMPOSITOR_CONF_OPTS = \
	-DCMAKE_C_STANDARD=99 \
	-DCMAKE_C_STANDARD_REQUIRED=ON \
	-DCMAKE_C_EXTENSIONS=OFF \
	-DBUILD_TESTS=OFF

# Install the compositor binary and test client
define PLAYOS_COMPOSITOR_INSTALL_EXTRA
	$(INSTALL) -D -m 0755 $(@D)/playos-test-client $(TARGET_DIR)/usr/bin/playos-test-client
endef
PLAYOS_COMPOSITOR_POST_INSTALL_TARGET_HOOKS += PLAYOS_COMPOSITOR_INSTALL_EXTRA

$(eval $(cmake-package))

