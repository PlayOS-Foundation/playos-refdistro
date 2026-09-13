cmake_minimum_required(VERSION 3.16)
project(playos-recovery C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT wayland-client REQUIRED)

# wayland-scanner comes from host-wayland ($(HOST_DIR)/bin/wayland-scanner)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

# ── xdg-shell client protocol ─────────────────────────────────────────────
# Provided by wayland-protocols; the client needs the stable interface to make
# itself a toplevel. Generated at build time, like the shell does.
pkg_get_variable(WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
if(NOT WAYLAND_PROTOCOLS_DIR)
    message(FATAL_ERROR "wayland-protocols pkgdatadir not found")
endif()
set(XDG_SHELL_XML "${WAYLAND_PROTOCOLS_DIR}/stable/xdg-shell/xdg-shell.xml")

set(GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/gen")
file(MAKE_DIRECTORY ${GEN_DIR})

add_custom_command(
    OUTPUT ${GEN_DIR}/xdg-shell-client-protocol.h ${GEN_DIR}/xdg-shell-protocol.c
    COMMAND ${WAYLAND_SCANNER} client-header ${XDG_SHELL_XML} ${GEN_DIR}/xdg-shell-client-protocol.h
    COMMAND ${WAYLAND_SCANNER} private-code  ${XDG_SHELL_XML} ${GEN_DIR}/xdg-shell-protocol.c
    DEPENDS ${XDG_SHELL_XML}
    COMMENT "Generating xdg-shell client protocol"
)
add_custom_target(playos-recovery-protocols DEPENDS
    ${GEN_DIR}/xdg-shell-client-protocol.h ${GEN_DIR}/xdg-shell-protocol.c)

# ── trusted IPC (playos-runtime, installed into the sysroot) ──────────────
find_library(TRUSTED_LIB playos-trusted
    HINTS ${CMAKE_SYSROOT}/usr/lib
    REQUIRED)
find_path(TRUSTED_INCLUDE_DIR playos-runtime/trusted_control.h
    HINTS ${CMAKE_SYSROOT}/usr/include
    REQUIRED)

# ── executable ────────────────────────────────────────────────────────────
add_executable(playos-recovery
    main.c
    ${GEN_DIR}/xdg-shell-protocol.c)
add_dependencies(playos-recovery playos-recovery-protocols)

target_include_directories(playos-recovery PRIVATE
    ${GEN_DIR}
    ${TRUSTED_INCLUDE_DIR}
    ${WAYLAND_CLIENT_INCLUDE_DIRS}
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party
)

target_link_directories(playos-recovery PRIVATE
    ${WAYLAND_CLIENT_LIBRARY_DIRS}
)

target_link_libraries(playos-recovery PRIVATE
    ${WAYLAND_CLIENT_LIBRARIES}
    ${TRUSTED_LIB}
    m
)

target_compile_definitions(playos-recovery PRIVATE
    _DEFAULT_SOURCE
)

if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(playos-recovery PRIVATE
        -Wall -Wextra -Wno-unused-parameter)
endif()

include(GNUInstallDirs)
install(TARGETS playos-recovery RUNTIME DESTINATION bin)
