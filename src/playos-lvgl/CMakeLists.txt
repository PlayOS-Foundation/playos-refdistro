# playos-lvgl — LVGL v9 built once, shared by the shell and the overlay.
#
# Mirrors src/playos-raylib: a thin wrapper around the vendored LVGL tree (which
# stays in playos-shell/external/lvgl, the way raylib does) so that both trusted
# UIs link one copy instead of each building their own.
#
# The ARM assembly blends are absent from the vendored tree on purpose: LVGL's
# source glob collects them regardless of configuration and they cannot assemble
# on x86-64. See playos-memorymap/08-gotchas.md.
cmake_minimum_required(VERSION 3.25)
project(playos-lvgl
    VERSION 9.5.0
    DESCRIPTION "LVGL v9 for the PlayOS shell and overlay"
    LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

if(NOT PLAYOS_LVGL_SOURCE_DIR)
    message(FATAL_ERROR "PLAYOS_LVGL_SOURCE_DIR must point at the vendored LVGL tree")
endif()

set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)   # one copy for shell + overlay
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_DEMOS OFF CACHE BOOL "" FORCE)

# LVGL's os_desktop.cmake resolves lv_conf.h as ${CMAKE_SOURCE_DIR}/lv_conf.h and
# ignores LV_CONF_PATH, so this project carries a real copy. The hash check below
# keeps it honest: the two files are the same configuration or the build stops.
file(SHA256 "${PLAYOS_LVGL_SOURCE_DIR}/lv_conf.h" _conf_vendored)
file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/lv_conf.h" _conf_wrapper)
if(NOT _conf_vendored STREQUAL _conf_wrapper)
    message(FATAL_ERROR
        "src/playos-lvgl/lv_conf.h has drifted from playos-shell/external/lvgl/lv_conf.h - "
        "copy the vendored file over the wrapper's.")
endif()

add_subdirectory(${PLAYOS_LVGL_SOURCE_DIR} ${CMAKE_CURRENT_BINARY_DIR}/lvgl)

# Headers: the top-level ones plus the whole source tree, matching how LVGL is
# consumed by a normal project.
install(TARGETS lvgl LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
install(FILES
    ${PLAYOS_LVGL_SOURCE_DIR}/lvgl.h
    ${PLAYOS_LVGL_SOURCE_DIR}/lv_version.h
    ${PLAYOS_LVGL_SOURCE_DIR}/lvgl_private.h
    ${PLAYOS_LVGL_SOURCE_DIR}/lv_conf.h
    DESTINATION include)
install(DIRECTORY ${PLAYOS_LVGL_SOURCE_DIR}/src
    DESTINATION include
    FILES_MATCHING PATTERN "*.h")
