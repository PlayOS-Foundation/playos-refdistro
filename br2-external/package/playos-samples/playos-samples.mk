################################################################################
# playos-samples — reference sample games (Sprint 6)
#
# The four samples (audio-sine, input-debug, triangle, rotating-squares) each
# ship their own CMakeLists.txt targeting an executable named `game`, so they
# cannot be pulled in with `add_subdirectory` — a cmake-package would collide
# on the target name. Instead we build each one directly with the cross
# toolchain via generic-package, then install it into the read-only rootfs at
# /usr/share/playos/games/<app-id>/. On first boot playos-init seeds these
# into the writable data partition under /data/games/<app-id>/.
#
# rotating-squares additionally links the shared libraylib (playos-raylib
# package) to exercise the PLATFORM_PLAYOS Wayland/EGL/GLES2 backend.
################################################################################

PLAYOS_SAMPLES_VERSION = 0.1.0
PLAYOS_SAMPLES_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-samples
PLAYOS_SAMPLES_SITE_METHOD = local
PLAYOS_SAMPLES_DEPENDENCIES = playos-platform-api playos-raylib

# Build each sample with the target (musl) toolchain. The toolchain wrapper
# adds --sysroot=$(STAGING_DIR), so <playos/playos.h> and -lplayos resolve
# against the staging tree automatically.
define PLAYOS_SAMPLES_BUILD_CMDS
	for d in input-debug triangle; do \
		mkdir -p $(@D)/$$d/bin; \
		$(TARGET_CC) $(TARGET_CFLAGS) -std=c99 \
			-o $(@D)/$$d/bin/game $(@D)/$$d/src/main.c \
			$(TARGET_LDFLAGS) -lplayos || exit 1; \
	done
	mkdir -p $(@D)/audio-sine/bin
	$(TARGET_CC) $(TARGET_CFLAGS) -std=c99 \
		-o $(@D)/audio-sine/bin/game $(@D)/audio-sine/src/main.c \
		$(TARGET_LDFLAGS) -lraylib -lplayos -lm || exit 1
	mkdir -p $(@D)/rotating-squares/bin
	$(TARGET_CC) $(TARGET_CFLAGS) -std=c99 \
		-o $(@D)/rotating-squares/bin/game $(@D)/rotating-squares/src/main.c \
		$(TARGET_LDFLAGS) -lraylib -lplayos -lm || exit 1
endef

# Install each sample into the read-only library seed location. playos-init
# copies these into /data/games/<app-id>/ on the first boot of a fresh data
# partition, so the shipped titles appear in the on-device library.
define PLAYOS_SAMPLES_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/audio-sine/bin/game \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-audio/bin/game
	$(INSTALL) -D -m 0644 $(@D)/audio-sine/manifest.json \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-audio/manifest.json
	$(INSTALL) -D -m 0644 $(@D)/audio-sine/assets/icon.png \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-audio/assets/icon.png

	$(INSTALL) -D -m 0755 $(@D)/input-debug/bin/game \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-input/bin/game
	$(INSTALL) -D -m 0644 $(@D)/input-debug/manifest.json \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-input/manifest.json
	$(INSTALL) -D -m 0644 $(@D)/input-debug/assets/icon.png \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-input/assets/icon.png

	$(INSTALL) -D -m 0755 $(@D)/triangle/bin/game \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-triangle/bin/game
	$(INSTALL) -D -m 0644 $(@D)/triangle/manifest.json \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-triangle/manifest.json
	$(INSTALL) -D -m 0644 $(@D)/triangle/assets/icon.png \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-triangle/assets/icon.png

	$(INSTALL) -D -m 0755 $(@D)/rotating-squares/bin/game \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-rotating-squares/bin/game
	$(INSTALL) -D -m 0644 $(@D)/rotating-squares/manifest.json \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-rotating-squares/manifest.json
	$(INSTALL) -D -m 0644 $(@D)/rotating-squares/assets/icon.png \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-rotating-squares/assets/icon.png
endef

$(eval $(generic-package))
