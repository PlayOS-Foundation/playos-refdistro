################################################################################
# playos-platform-api (libplayos) — Sprint 0 stub
################################################################################

PLAYOS_PLATFORM_API_VERSION = 0.1.0
PLAYOS_PLATFORM_API_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/package/playos-platform-api
PLAYOS_PLATFORM_API_SITE_METHOD = local

define PLAYOS_PLATFORM_API_BUILD_CMDS
	@true
endef

define PLAYOS_PLATFORM_API_INSTALL_TARGET_CMDS
	@true
endef

$(eval $(generic-package))
