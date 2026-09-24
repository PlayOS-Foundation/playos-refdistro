cmake_minimum_required(VERSION 3.16)
project(playos-net C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The canonical IPC framing/server sources live in playos-init/ipc. A local
# Buildroot site is copied into output/.../build, so the package .mk passes this
# path explicitly rather than relying on a relative default.
set(PLAYOS_IPC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../playos-init/ipc"
    CACHE PATH "Path to the canonical IPC sources (ipc.h, ipc_framing.c, ipc_client.c, ipc_server.c)")

add_executable(playos-net
    src/main.c
    src/wpa_bridge.c
    src/profiles.c
    ${PLAYOS_IPC_DIR}/ipc_framing.c
    ${PLAYOS_IPC_DIR}/ipc_client.c
    ${PLAYOS_IPC_DIR}/ipc_server.c
)

target_include_directories(playos-net PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${PLAYOS_IPC_DIR}
)

# libwpa_client is provided by wpa_supplicant
# (BR2_PACKAGE_WPA_SUPPLICANT_WPA_CLIENT_SO), which also installs wpa_ctrl.h.
target_link_libraries(playos-net PRIVATE wpa_client)

install(TARGETS playos-net RUNTIME DESTINATION bin)
