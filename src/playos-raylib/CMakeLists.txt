cmake_minimum_required(VERSION 3.25)
project(playos-raylib
    VERSION 6.0.0
    DESCRIPTION "Raylib 6.0 with the PlayOS Wayland/EGL backend"
    LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# ── Dependencies ────────────────────────────────────────────────────────
find_package(PkgConfig REQUIRED)

# Wayland scanner (host-wayland provides $(HOST_DIR)/bin/wayland-scanner)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

# xdg-shell protocol shipped with wayland-protocols
pkg_get_variable(WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
set(XDG_SHELL_XML "${WAYLAND_PROTOCOLS_DIR}/stable/xdg-shell/xdg-shell.xml")

# ── Generate Wayland protocol bindings ──────────────────────────────────
set(PROTOCOL_XML "${CMAKE_CURRENT_SOURCE_DIR}/protocols/playos-v1.xml")
set(GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/gen")
file(MAKE_DIRECTORY ${GEN_DIR})

add_custom_command(
    OUTPUT ${GEN_DIR}/playos-v1-client-protocol.h ${GEN_DIR}/playos-v1-protocol.c
    COMMAND ${WAYLAND_SCANNER} client-header ${PROTOCOL_XML} ${GEN_DIR}/playos-v1-client-protocol.h
    COMMAND ${WAYLAND_SCANNER} private-code  ${PROTOCOL_XML} ${GEN_DIR}/playos-v1-protocol.c
    DEPENDS ${PROTOCOL_XML}
    COMMENT "Generating PlayOS Wayland client protocol"
)

add_custom_command(
    OUTPUT ${GEN_DIR}/xdg-shell-client-protocol.h ${GEN_DIR}/xdg-shell-protocol.c
    COMMAND ${WAYLAND_SCANNER} client-header ${XDG_SHELL_XML} ${GEN_DIR}/xdg-shell-client-protocol.h
    COMMAND ${WAYLAND_SCANNER} private-code  ${XDG_SHELL_XML} ${GEN_DIR}/xdg-shell-protocol.c
    DEPENDS ${XDG_SHELL_XML}
    COMMENT "Generating xdg-shell client protocol"
)

add_custom_target(playos-protocols
    DEPENDS
        ${GEN_DIR}/playos-v1-client-protocol.h
        ${GEN_DIR}/playos-v1-protocol.c
        ${GEN_DIR}/xdg-shell-client-protocol.h
        ${GEN_DIR}/xdg-shell-protocol.c)

# ── Configure and build vendored Raylib (PlayOS backend) ───────────────
# The vendored raylib lives in playos-shell/external/raylib. Buildroot passes
# its absolute path via PLAYOS_RAYLIB_SOURCE_DIR (a relative symlink would
# not survive the rsync into the build tree); the fallback supports host
# development builds from this source directory.
set(PLAYOS_RAYLIB_SOURCE_DIR "" CACHE PATH
    "Path to the vendored raylib source tree (external/raylib)")
if(NOT PLAYOS_RAYLIB_SOURCE_DIR)
    set(PLAYOS_RAYLIB_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/external/raylib")
endif()

set(PLATFORM "PlayOS" CACHE STRING "raylib platform" FORCE)
set(OPENGL_VERSION "ES 2.0" CACHE STRING "raylib OpenGL version" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "Build raylib examples" FORCE)

add_subdirectory(${PLAYOS_RAYLIB_SOURCE_DIR} raylib)

# rcore_playos.c owns the Wayland/EGL protocol usage, so the generated
# protocol bindings belong to the raylib target.
target_include_directories(raylib PRIVATE ${GEN_DIR})
target_sources(raylib PRIVATE
    ${GEN_DIR}/playos-v1-protocol.c
    ${GEN_DIR}/xdg-shell-protocol.c)
add_dependencies(raylib playos-protocols)
