cmake_minimum_required(VERSION 3.18)
project(playos-installer
    VERSION 0.1.0
    DESCRIPTION "PlayOS trusted internal-disk installer (Raylib + Wayland client)"
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
# The installer links libraylib.so, which builds the PlayOS backend with
# hidden visibility; its internal copies of these symbols are not exported.
# The installer therefore generates and compiles its own (wire-identical)
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

add_custom_target(playos-installer-protocols
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

# ── libfdisk (util-linux, GPT partitioning) ─────────────────────────────
find_library(FDISK_LIB fdisk
    HINTS ${CMAKE_SYSROOT}/usr/lib
    REQUIRED)
find_path(FDISK_INCLUDE_DIR libfdisk/libfdisk.h
    HINTS ${CMAKE_SYSROOT}/usr/include
    REQUIRED)

# ── Executable ──────────────────────────────────────────────────────────
add_executable(playos-installer
    main.c
    disk.c
    format.c
    efi.c
    ${GEN_DIR}/playos-v1-protocol.c)
add_dependencies(playos-installer playos-installer-protocols)

target_include_directories(playos-installer PRIVATE
    ${GEN_DIR}
    ${RAYLIB_INCLUDE_DIR}
    ${FDISK_INCLUDE_DIR}
    ${WAYLAND_CLIENT_INCLUDE_DIRS}
)

target_link_directories(playos-installer PRIVATE
    ${WAYLAND_CLIENT_LIBRARY_DIRS}
)

target_link_libraries(playos-installer PRIVATE
    ${WAYLAND_CLIENT_LIBRARIES}
    ${RAYLIB_LIB}
    ${FDISK_LIB}
    m
)

target_compile_definitions(playos-installer PRIVATE
    _POSIX_C_SOURCE=199309L
    _DEFAULT_SOURCE
)

if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(playos-installer PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# ── Installation ───────────────────────────────────────────────────────
include(GNUInstallDirs)
install(TARGETS playos-installer RUNTIME DESTINATION bin)
