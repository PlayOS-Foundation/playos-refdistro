################################################################################
# playos-init — PID 1 process supervisor (Sprint 1)
#
# Replaces the BusyBox /init shell script with a real C99 binary.
# Built with Buildroot's cmake-package infrastructure.
################################################################################

PLAYOS_INIT_VERSION = 0.3.0
PLAYOS_INIT_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-init
PLAYOS_INIT_SITE_METHOD = local
PLAYOS_INIT_INSTALL_STAGING = NO

# C99, static linking, musl toolchain
PLAYOS_INIT_CONF_OPTS = \
	-DCMAKE_C_STANDARD=99 \
	-DCMAKE_C_STANDARD_REQUIRED=ON \
	-DCMAKE_C_EXTENSIONS=OFF

# Install the binary as /init (PID 1 expects it there)
define PLAYOS_INIT_INSTALL_INIT
	$(INSTALL) -D -m 0755 $(@D)/playos-init $(TARGET_DIR)/init
endef
PLAYOS_INIT_POST_INSTALL_TARGET_HOOKS += PLAYOS_INIT_INSTALL_INIT

$(eval $(cmake-package))
