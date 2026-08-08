################################################################################
# playos-compositor — Sprint 0 stub
################################################################################

PLAYOS_COMPOSITOR_VERSION = 0.1.0
PLAYOS_COMPOSITOR_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/package/playos-compositor
PLAYOS_COMPOSITOR_SITE_METHOD = local

define PLAYOS_COMPOSITOR_BUILD_CMDS
	@true
endef

define PLAYOS_COMPOSITOR_INSTALL_TARGET_CMDS
	@true
endef

$(eval $(generic-package))
