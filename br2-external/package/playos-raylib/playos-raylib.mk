################################################################################
# playos-raylib — Raylib 6.0 with the PlayOS Wayland/EGL/GLES2 backend
#
# Promotes the vendored Raylib in playos-shell/external/raylib into a shared
# Buildroot package so samples (and future games/apps) can link -lraylib
# without pulling in the whole shell. The wrapper CMakeLists.txt mirrors the
# shell's raylib configuration: PLATFORM=PlayOS + OPENGL_VERSION=ES 2.0, with
# the playos-v1 and xdg-shell Wayland protocol bindings injected into the
# raylib target so rcore_playos.c can bind the compositor.
#
# Built as a shared library (libraylib.so.600) and installed to staging so
# downstream packages can #include <raylib.h> and link -lraylib.
################################################################################

PLAYOS_RAYLIB_VERSION = 6.0.0
PLAYOS_RAYLIB_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-raylib
PLAYOS_RAYLIB_SITE_METHOD = local
PLAYOS_RAYLIB_INSTALL_STAGING = YES
PLAYOS_RAYLIB_DEPENDENCIES = wayland wayland-protocols mesa3d alsa-lib playos-platform-api

# Point the wrapper at the single vendored raylib source (kept in the shell).
PLAYOS_RAYLIB_CONF_OPTS = \
	-DPLAYOS_RAYLIB_SOURCE_DIR=$(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-shell/external/raylib

$(eval $(cmake-package))
