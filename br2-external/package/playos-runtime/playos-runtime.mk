################################################################################
# playos-runtime — Protocol definitions and runtime helpers (Sprint 2.5)
################################################################################

PLAYOS_RUNTIME_VERSION = 0.1.0
PLAYOS_RUNTIME_SITE = $(TOPDIR)/../src/playos-runtime
PLAYOS_RUNTIME_SITE_METHOD = local
PLAYOS_RUNTIME_INSTALL_STAGING = YES

# IPC sources are in playos-init, alongside playos-runtime in src/
PLAYOS_RUNTIME_CONF_OPTS = \
	-DPLAYOS_IPC_DIR=$(TOPDIR)/../src/playos-init/ipc

# CMake install handles the library + headers + protocols.
# We supplement staging with the IPC header (needed to build trusted clients).
define PLAYOS_RUNTIME_INSTALL_STAGING_CMDS
	mkdir -p $(STAGING_DIR)/usr/include/playos-runtime
	cp $(@D)/include/playos-runtime/trusted_control.h \
	   $(STAGING_DIR)/usr/include/playos-runtime/
	# CMake installs the .a via install(TARGETS), but we ensure it:
	cp $(@D)/libplayos-trusted.a $(STAGING_DIR)/usr/lib/ 2>/dev/null || true
endef

define PLAYOS_RUNTIME_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/playos/protocols
	cp $(@D)/protocols/playos-v1.xml $(TARGET_DIR)/usr/share/playos/protocols/
endef

$(eval $(cmake-package))
