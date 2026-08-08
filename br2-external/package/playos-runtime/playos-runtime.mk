################################################################################
# playos-runtime — Protocol definitions and runtime helpers (Sprint 2.5)
################################################################################

PLAYOS_RUNTIME_VERSION = 0.1.0
PLAYOS_RUNTIME_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-runtime
PLAYOS_RUNTIME_SITE_METHOD = local
PLAYOS_RUNTIME_INSTALL_STAGING = YES

PLAYOS_RUNTIME_CONF_OPTS = -DBUILD_TESTS=OFF

define PLAYOS_RUNTIME_INSTALL_STAGING_CMDS
	mkdir -p $(STAGING_DIR)/usr/share/playos/protocols
	cp $(@D)/protocols/playos-v1.xml $(STAGING_DIR)/usr/share/playos/protocols/
endef

define PLAYOS_RUNTIME_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/playos/protocols
	cp $(@D)/protocols/playos-v1.xml $(TARGET_DIR)/usr/share/playos/protocols/
endef

$(eval $(cmake-package))
