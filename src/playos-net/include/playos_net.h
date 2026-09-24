/*
 * playos_net.h — internal types for the PlayOS network bridge daemon
 *
 * playos-net owns the trusted side of Wi-Fi: it is the only process that talks
 * to wpa_supplicant, and it re-exposes that as the same JSON-over-SOCK_SEQPACKET
 * control protocol the rest of PlayOS uses (see playos-init/ipc/ipc.h and
 * playos-spec/src/runtime-ipc.md). Games never reach it; the bridge socket is
 * owned root:playos-trusted 0660 and every peer is checked with SO_PEERCRED.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef PLAYOS_NET_H
#define PLAYOS_NET_H

#include <stddef.h>

#define PLAYOS_NET_PROTO_VERSION  1

#define PLAYOS_NET_SOCKET_DEFAULT   "/run/playos/net/bridge.sock"
#define PLAYOS_NET_CTRL_DIR_DEFAULT "/run/playos/net"
#define PLAYOS_NET_PROFILES_DEFAULT "/data/config/network"
#define PLAYOS_NET_TRUSTED_GROUP    "playos-trusted"

#define PLAYOS_NET_MAX_RESULTS      64
#define PLAYOS_NET_SSID_MAX         64
#define PLAYOS_NET_SEC_MAX          16
#define PLAYOS_NET_JSON_MAX         (32 * 1024)

/* Message types (canonical strings live in playos-init/ipc/ipc.h). */
#define PLAYOS_NET_REQ_SCAN        "ScanNetworks"
#define PLAYOS_NET_REQ_CONNECT     "ConnectNetwork"
#define PLAYOS_NET_REQ_DISCONNECT  "DisconnectNetwork"
#define PLAYOS_NET_REQ_STATUS      "NetworkStatus"
#define PLAYOS_NET_EV_STATE        "NetworkStateChanged"

/* One access point as reported to the shell. */
typedef struct {
    char ssid[PLAYOS_NET_SSID_MAX * 4 + 1];
    char security[PLAYOS_NET_SEC_MAX];   /* open|wep|wpa|wpa2|wpa3 */
    int  signal_dbm;
} playos_net_ap;

/* ── wpa_bridge.c ─────────────────────────────────────────────────────── */

typedef struct playos_wpa playos_wpa;

/* Connect to wpa_supplicant's control socket at <ctrl_dir>/<ifname> and attach
 * an event monitor. Returns NULL if wpa_supplicant is not up yet (errno in
 * *err); callers retry. */
playos_wpa *wpa_open(const char *ctrl_dir, const char *ifname, int *err);
void        wpa_close(playos_wpa *w);

/* Event-monitor fd for poll(), or -1 when no monitor is attached. */
int         wpa_event_fd(const playos_wpa *w);

/* Read one pending wpa event and classify it for NetworkStateChanged:
 * "connected", "connecting", "disconnected", or NULL when nothing is pending. */
const char *wpa_poll_event(playos_wpa *w);

/* Trigger a scan and return the parsed result set (strongest per SSID).
 * Returns 0 on success (*count may be 0 if the scan found nothing yet). */
int wpa_scan(playos_wpa *w, playos_net_ap *out, int max, int *count);

/* Current link state. state is "connected"/"connecting"/"disconnected". */
int wpa_status(playos_wpa *w, char *state, size_t state_sz,
               char *ssid, size_t ssid_sz, char *ip, size_t ip_sz,
               int *signal_dbm);

/* Add + select a network. On failure fills `reason` ("auth_failed",
 * "not_found", "no_wpa" ...). */
int wpa_connect(playos_wpa *w, const char *ssid, const char *psk,
                const char *security, char *reason, size_t reason_sz);

int wpa_disconnect(playos_wpa *w);

/* ── profiles.c ───────────────────────────────────────────────────────── */

/* Persist a known network (0600; the PSK never goes to the log). */
int profiles_save(const char *dir, const char *ssid, const char *security,
                  const char *psk);

/* Load the most recently used profile. Returns 0 when one was found. */
int profiles_load_last(const char *dir, char *ssid, size_t ssid_sz,
                       char *security, size_t sec_sz,
                       char *psk, size_t psk_sz);

/* ── helpers ──────────────────────────────────────────────────────────── */

/* First interface under /sys/class/net with a `wireless` directory (the Ally's
 * is wlp6s0 — never hardcode a name). */
int net_discover_ifname(char *out, size_t out_sz);

/* Minimal JSON string/number extraction for our own request bodies. */
int net_json_str(const char *json, const char *key, char *out, size_t out_sz);
int net_json_int(const char *json, const char *key, int *out);

#endif /* PLAYOS_NET_H */
