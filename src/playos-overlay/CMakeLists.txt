cmake_minimum_required(VERSION 3.18)
project(playos-overlay
    VERSION 0.1.0
    DESCRIPTION "PlayOS trusted in-game overlay (Raylib + Wayland client)"
    LANGUAGES C
)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# ── Dependencies ────────────────────────────────────────────────────────
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT wayland-client REQUIRED)

# Wayland scanner (host-wayland provides $(HOST_DIR)/bin/wayland-scanner)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

# ── Generate PlayOS client protocol bindings ────────────────────────────
# The overlay links libraylib.so, which builds the PlayOS backend with
# hidden visibility; its internal copies of these symbols are not exported.
# The overlay therefore generates and compiles its own (wire-identical)
# protocol bindings instead of relying on the shared library.
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

add_custom_target(playos-overlay-protocols
    DEPENDS
        ${GEN_DIR}/playos-v1-client-protocol.h
        ${GEN_DIR}/playos-v1-protocol.c)

# ── Raylib (shared, installed to staging by playos-raylib) ──────────────
find_library(RAYLIB_LIB raylib
    HINTS ${CMAKE_SYSROOT}/usr/lib
    REQUIRED)
find_path(RAYLIB_INCLUDE_DIR raylib.h
    HINTS ${CMAKE_SYSROOT}/usr/include
    REQUIRED)

# ── Trusted IPC (libplayos-trusted from playos-runtime) ─────────────────
find_library(PLAYOS_TRUSTED_LIB playos-trusted
    HINTS ${CMAKE_SYSROOT}/usr/lib
    REQUIRED)
find_path(PLAYOS_RUNTIME_INCLUDE_DIR playos-runtime/trusted_control.h
    HINTS ${CMAKE_SYSROOT}/usr/include
    REQUIRED)

# ── Public Platform API (libplayos: audio volume/mute control) ──────────
find_library(PLAYOS_LIB playos
    HINTS ${CMAKE_SYSROOT}/usr/lib
    REQUIRED)
find_path(PLAYOS_INCLUDE_DIR playos/playos.h
    HINTS ${CMAKE_SYSROOT}/usr/include
    REQUIRED)

# ── Executable ──────────────────────────────────────────────────────────
add_executable(playos-overlay
    main.c
    ${GEN_DIR}/playos-v1-protocol.c)
add_dependencies(playos-overlay playos-overlay-protocols)

target_include_directories(playos-overlay PRIVATE
    ${GEN_DIR}
    ${RAYLIB_INCLUDE_DIR}
    ${PLAYOS_RUNTIME_INCLUDE_DIR}
    ${PLAYOS_INCLUDE_DIR}
    ${WAYLAND_CLIENT_INCLUDE_DIRS}
)

target_link_directories(playos-overlay PRIVATE
    ${WAYLAND_CLIENT_LIBRARY_DIRS}
)

target_link_libraries(playos-overlay PRIVATE
    ${WAYLAND_CLIENT_LIBRARIES}
    ${RAYLIB_LIB}
    ${PLAYOS_TRUSTED_LIB}
    ${PLAYOS_LIB}
    m
)

target_compile_definitions(playos-overlay PRIVATE
    _POSIX_C_SOURCE=199309L
    _DEFAULT_SOURCE
)

if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(playos-overlay PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# ── Installation ───────────────────────────────────────────────────────
include(GNUInstallDirs)
install(TARGETS playos-overlay RUNTIME DESTINATION bin)
