################################################################################
# playos-init — Sprint 0 stub (replaced by real implementation in Sprint 1)
################################################################################

PLAYOS_INIT_VERSION = 0.1.0
PLAYOS_INIT_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/package/playos-init
PLAYOS_INIT_SITE_METHOD = local

# Sprint 0: no-op — BusyBox /init handles boot. Real implementation in Sprint 1.
define PLAYOS_INIT_BUILD_CMDS
	@true
endef

define PLAYOS_INIT_INSTALL_TARGET_CMDS
	@true
endef

$(eval $(generic-package))
