################################################################################
# playos-runtime — Sprint 0 stub
################################################################################

PLAYOS_RUNTIME_VERSION = 0.1.0
PLAYOS_RUNTIME_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/package/playos-runtime
PLAYOS_RUNTIME_SITE_METHOD = local

define PLAYOS_RUNTIME_BUILD_CMDS
	@true
endef

define PLAYOS_RUNTIME_INSTALL_TARGET_CMDS
	@true
endef

$(eval $(generic-package))
