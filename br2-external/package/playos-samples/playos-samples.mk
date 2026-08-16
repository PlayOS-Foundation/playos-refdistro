################################################################################
# playos-samples — reference sample games (Sprint 6)
#
# The samples (audio-sine, audio-module, controller-visualizer, input-debug,
# triangle, rotating-squares, bullet-hell, colors-palette) each ship their own
# CMakeLists.txt targeting an
# executable named `game`, so they
# cannot be pulled in with `add_subdirectory` — a cmake-package would collide
# on the target name. Instead we build each one directly with the cross
# toolchain via generic-package, then install it into the read-only rootfs at
# /usr/share/playos/games/<app-id>/. On first boot playos-init seeds these
# into the writable data partition under /data/games/<app-id>/.
#
# rotating-squares additionally links the shared libraylib (playos-raylib
# package) to exercise the PLATFORM_PLAYOS Wayland/EGL/GLES2 backend.
# audio-module is the first sample to ship a runtime resource (its .xm module
# under resources/), which is installed alongside bin/game and seeded into
# /data/games/<app-id>/ by playos-init's recursive copy_tree.
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
	mkdir -p $(@D)/controller-visualizer/bin
	$(TARGET_CC) $(TARGET_CFLAGS) -std=c99 \
		-o $(@D)/controller-visualizer/bin/game $(@D)/controller-visualizer/src/main.c \
		$(TARGET_LDFLAGS) -lraylib -lplayos -lm || exit 1
	mkdir -p $(@D)/audio-module/bin
	$(TARGET_CC) $(TARGET_CFLAGS) -std=c99 \
		-o $(@D)/audio-module/bin/game $(@D)/audio-module/src/main.c \
		$(TARGET_LDFLAGS) -lraylib -lplayos -lm || exit 1
	mkdir -p $(@D)/bullet-hell/bin
	$(TARGET_CC) $(TARGET_CFLAGS) -std=c99 \
		-o $(@D)/bullet-hell/bin/game $(@D)/bullet-hell/src/main.c \
		$(TARGET_LDFLAGS) -lraylib -lplayos -lm || exit 1
	mkdir -p $(@D)/colors-palette/bin
	$(TARGET_CC) $(TARGET_CFLAGS) -std=c99 \
		-o $(@D)/colors-palette/bin/game $(@D)/colors-palette/src/main.c \
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

	$(INSTALL) -D -m 0755 $(@D)/controller-visualizer/bin/game \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-controller-visualizer/bin/game
	$(INSTALL) -D -m 0644 $(@D)/controller-visualizer/manifest.json \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-controller-visualizer/manifest.json
	$(INSTALL) -D -m 0644 $(@D)/controller-visualizer/assets/icon.png \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-controller-visualizer/assets/icon.png

	$(INSTALL) -D -m 0755 $(@D)/audio-module/bin/game \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-audio-module/bin/game
	$(INSTALL) -D -m 0644 $(@D)/audio-module/manifest.json \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-audio-module/manifest.json
	$(INSTALL) -D -m 0644 $(@D)/audio-module/assets/icon.png \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-audio-module/assets/icon.png
	$(INSTALL) -D -m 0644 $(@D)/audio-module/resources/mini1111.xm \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-audio-module/resources/mini1111.xm

	$(INSTALL) -D -m 0755 $(@D)/bullet-hell/bin/game \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-bullet-hell/bin/game
	$(INSTALL) -D -m 0644 $(@D)/bullet-hell/manifest.json \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-bullet-hell/manifest.json
	$(INSTALL) -D -m 0644 $(@D)/bullet-hell/assets/icon.png \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-bullet-hell/assets/icon.png

	$(INSTALL) -D -m 0755 $(@D)/colors-palette/bin/game \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-colors-palette/bin/game
	$(INSTALL) -D -m 0644 $(@D)/colors-palette/manifest.json \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-colors-palette/manifest.json
	$(INSTALL) -D -m 0644 $(@D)/colors-palette/assets/icon.png \
		$(TARGET_DIR)/usr/share/playos/games/com.playos.sample-colors-palette/assets/icon.png
endef

$(eval $(generic-package))
