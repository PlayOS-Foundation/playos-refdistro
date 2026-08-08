################################################################################
# playos-shell — Sprint 0 stub
################################################################################

PLAYOS_SHELL_VERSION = 0.1.0
PLAYOS_SHELL_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/package/playos-shell
PLAYOS_SHELL_SITE_METHOD = local

define PLAYOS_SHELL_BUILD_CMDS
	@true
endef

define PLAYOS_SHELL_INSTALL_TARGET_CMDS
	@true
endef

$(eval $(generic-package))
