################################################################################
# playos-platform-api (libplayos) — Sprint 3
################################################################################

PLAYOS_PLATFORM_API_VERSION = 0.3.0
PLAYOS_PLATFORM_API_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-platform-api
PLAYOS_PLATFORM_API_SITE_METHOD = local
PLAYOS_PLATFORM_API_INSTALL_STAGING = YES

PLAYOS_PLATFORM_API_CONF_OPTS = \
	-DCMAKE_C_STANDARD=99 \
	-DCMAKE_C_STANDARD_REQUIRED=ON \
	-DCMAKE_C_EXTENSIONS=OFF \
	-DPLAYOS_BACKEND=evdev \
	-DPLAYOS_BUILD_TESTS=OFF

$(eval $(cmake-package))
