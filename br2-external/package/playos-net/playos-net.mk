################################################################################
# playos-net — PlayOS Wi-Fi bridge daemon (Sprint 16, T3)
#
# The only process that talks to wpa_supplicant. It re-exposes Wi-Fi as the
# same JSON-over-SOCK_SEQPACKET control protocol the rest of PlayOS uses, on
# /run/playos/net/bridge.sock (root:playos-trusted, 0660). Games are not in
# playos-trusted, so they can never reach it (ADR-0012).
################################################################################

PLAYOS_NET_VERSION = 0.1.0
PLAYOS_NET_SITE = $(BR2_EXTERNAL_PlayOS_PATH)/../src/playos-net
PLAYOS_NET_SITE_METHOD = local
# libwpa_client + wpa_ctrl.h come from wpa_supplicant's WPA_CLIENT_SO option.
PLAYOS_NET_DEPENDENCIES = wpa_supplicant
PLAYOS_NET_INSTALL_STAGING = NO

# IPC framing/server sources are shared from playos-init (same tree), exactly as
# playos-runtime does — a local site is copied into output/build, so pass the
# real path.
PLAYOS_NET_CONF_OPTS = \
	-DCMAKE_C_STANDARD=99 \
	-DPLAYOS_IPC_DIR=$(TOPDIR)/../src/playos-init/ipc

$(eval $(cmake-package))
