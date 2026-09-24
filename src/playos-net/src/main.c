/*
 * main.c — playos-net: the Wi-Fi bridge daemon (Sprint 16, T3)
 *
 * Owns the trusted side of networking:
 *
 *   shell/init ──JSON──▶ /run/playos/net/bridge.sock ──▶ playos-net
 *                                                          │  (wpa_ctrl)
 *                                                          ▼
 *                                                   wpa_supplicant
 *
 * The bridge socket is the same JSON-over-SOCK_SEQPACKET protocol as
 * /run/playos/control.sock (playos-init/ipc/ipc.h); the daemon is a server and
 * every peer is checked with SO_PEERCRED (root or playos-trusted only, so a game
 * gets EACCES). init relays ScanNetworks/ConnectNetwork from control.sock.
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include "playos_net.h"
#include "ipc.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_CLIENTS   8
#define FRAME_MAX     (sizeof(struct playos_ipc_frame) + PLAYOS_IPC_MAX_BODY)
#define WPA_RETRY_SEC 2

/* Mirrors ipc_server.c: playos-trusted is GID 1000, and a static musl
 * getgrnam() is not dependable in the initramfs. */
#define PLAYOS_NET_TRUSTED_GID 1000

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static void net_log(const char *lvl, const char *fmt, ...)
{
    va_list ap;

    fprintf(stderr, "[playos-net] %s: ", lvl);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

/* ── JSON helpers (our own request bodies only) ───────────────────────── */

int net_json_str(const char *json, const char *key, char *out, size_t out_sz)
{
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);

    const char *p = strstr(json, pat);
    if (!p)
        return -1;

    p = strchr(p + strlen(pat), ':');
    if (!p)
        return -1;
    p++;
    while (*p == ' ' || *p == '\t')
        p++;
    if (*p != '"')
        return -1;
    p++;

    size_t j = 0;
    while (*p && *p != '"' && j + 1 < out_sz) {
        if (*p == '\\' && p[1])
            p++;
        out[j++] = *p++;
    }
    out[j] = '\0';
    return 0;
}

int net_json_int(const char *json, const char *key, int *out)
{
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);

    const char *p = strstr(json, pat);
    if (!p)
        return -1;

    p = strchr(p + strlen(pat), ':');
    if (!p)
        return -1;

    *out = atoi(p + 1);
    return 0;
}

/* Bounded append — never overruns, and marks the buffer full when it truncates. */
static void appf(char *buf, size_t cap, size_t *off, const char *fmt, ...)
{
    if (*off >= cap)
        return;

    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf + *off, cap - *off, fmt, ap);
    va_end(ap);

    if (n < 0)
        return;
    if ((size_t)n >= cap - *off)
        *off = cap;                     /* truncated: stop appending */
    else
        *off += (size_t)n;
}

/* ── Wire helpers ─────────────────────────────────────────────────────── */

static void reply(int fd, const char *type, const char *extra_json)
{
    struct playos_ipc_message msg;

    if (playos_ipc_message_from_type(PLAYOS_NET_PROTO_VERSION, type,
                                     extra_json, &msg) != 0)
        return;

    if (playos_ipc_frame_write(fd, &msg) != 0)
        net_log("WARN", "frame_write failed for %s", type);

    playos_ipc_message_free(&msg);
}

/* ── Daemon state ─────────────────────────────────────────────────────── */

typedef struct {
    playos_wpa *wpa;
    const char *ctrl_dir;
    const char *profiles_dir;
    char        ifname[64];
    int         auto_connected;      /* last-profile auto-connect tried once */
} net_state;

/* Try to (re)connect to wpa_supplicant; cheap to call when already connected. */
static int ensure_wpa(net_state *st)
{
    if (st->wpa)
        return 0;

    int err = 0;
    st->wpa = wpa_open(st->ctrl_dir, st->ifname, &err);
    if (!st->wpa)
        return -1;

    net_log("INFO", "connected to wpa_supplicant (%s/%s)", st->ctrl_dir,
            st->ifname);

    /* T7: bring up the most recently used network without user input. */
    if (!st->auto_connected) {
        st->auto_connected = 1;

        char ssid[PLAYOS_NET_SSID_MAX * 4 + 1], sec[PLAYOS_NET_SEC_MAX], psk[128];
        if (profiles_load_last(st->profiles_dir, ssid, sizeof(ssid),
                               sec, sizeof(sec), psk, sizeof(psk)) == 0) {
            char reason[64];
            if (wpa_connect(st->wpa, ssid, psk, sec, reason, sizeof(reason)) == 0)
                net_log("INFO", "auto-connecting to saved network '%s'", ssid);
            else
                net_log("WARN", "auto-connect to '%s' failed (%s)", ssid, reason);
        }
    }

    return 0;
}

static void handle_request(net_state *st, int fd, const char *type,
                           const char *body)
{
    if (strcmp(type, "ScanNetworks") == 0) {
        if (ensure_wpa(st) != 0) {
            reply(fd, "Error", "\"error\":\"no_wpa\"");
            return;
        }

        static playos_net_ap aps[PLAYOS_NET_MAX_RESULTS];
        int n = 0;

        if (wpa_scan(st->wpa, aps, PLAYOS_NET_MAX_RESULTS, &n) != 0) {
            reply(fd, "Error", "\"error\":\"scan_failed\"");
            return;
        }

        char *json = malloc(PLAYOS_NET_JSON_MAX);
        if (!json)
            return;

        size_t off = 0;
        appf(json, PLAYOS_NET_JSON_MAX, &off, "\"networks\":[");
        for (int i = 0; i < n; i++) {
            appf(json, PLAYOS_NET_JSON_MAX, &off,
                 "%s{\"ssid\":\"%s\",\"security\":\"%s\",\"signal_dbm\":%d}",
                 i ? "," : "", aps[i].ssid, aps[i].security, aps[i].signal_dbm);
            if (off >= PLAYOS_NET_JSON_MAX)
                break;
        }
        appf(json, PLAYOS_NET_JSON_MAX, &off, "]");

        net_log("INFO", "scan: %d network(s)", n);
        reply(fd, "ScanResults", json);
        free(json);
        return;
    }

    if (strcmp(type, "NetworkStatus") == 0) {
        if (ensure_wpa(st) != 0) {
            reply(fd, "Error", "\"error\":\"no_wpa\"");
            return;
        }

        char state[24], ssid[PLAYOS_NET_SSID_MAX * 4 + 1], ip[64];
        int dbm = 0;
        if (wpa_status(st->wpa, state, sizeof(state), ssid, sizeof(ssid),
                       ip, sizeof(ip), &dbm) != 0) {
            reply(fd, "Error", "\"error\":\"status_failed\"");
            return;
        }

        char extra[512];
        snprintf(extra, sizeof(extra),
                 "\"state\":\"%s\",\"ssid\":\"%s\",\"ip\":\"%s\",\"signal_dbm\":%d",
                 state, ssid, ip, dbm);
        reply(fd, "NetworkStatusReport", extra);
        return;
    }

    if (strcmp(type, "ConnectNetwork") == 0) {
        char ssid[PLAYOS_NET_SSID_MAX * 4 + 1] = {0};
        char psk[256] = {0};
        char sec[PLAYOS_NET_SEC_MAX] = "wpa2";

        net_json_str(body, "ssid", ssid, sizeof(ssid));
        net_json_str(body, "psk", psk, sizeof(psk));
        net_json_str(body, "security", sec, sizeof(sec));

        char ack[512];
        snprintf(ack, sizeof(ack), "\"ssid\":\"%s\"", ssid);

        if (ensure_wpa(st) != 0) {
            reply(fd, "ConnectNetworkError",
                  "\"reason\":\"no_wpa\"");
            return;
        }

        char reason[64];
        if (wpa_connect(st->wpa, ssid, psk, sec, reason, sizeof(reason)) != 0) {
            char err[256];
            snprintf(err, sizeof(err), "\"ssid\":\"%s\",\"reason\":\"%s\"",
                     ssid, reason);
            net_log("WARN", "connect '%s' failed: %s", ssid, reason);
            reply(fd, "ConnectNetworkError", err);
            return;
        }

        /* Persist for reboot auto-connect. The PSK never reaches the log. */
        if (profiles_save(st->profiles_dir, ssid, sec, psk) != 0)
            net_log("WARN", "could not persist profile for '%s'", ssid);

        net_log("INFO", "connecting to '%s' (%s)", ssid, sec);
        reply(fd, "ConnectNetworkAck", ack);
        return;
    }

    if (strcmp(type, "DisconnectNetwork") == 0) {
        if (ensure_wpa(st) != 0) {
            reply(fd, "Error", "\"error\":\"no_wpa\"");
            return;
        }
        wpa_disconnect(st->wpa);
        net_log("INFO", "disconnected on request");
        reply(fd, "DisconnectNetworkAck", NULL);
        return;
    }

    net_log("WARN", "unknown request type '%s'", type);
    reply(fd, "Error", "\"error\":\"unknown_type\"");
}

int main(int argc, char **argv)
{
    const char *socket_path = PLAYOS_NET_SOCKET_DEFAULT;
    const char *ctrl_dir = PLAYOS_NET_CTRL_DIR_DEFAULT;
    const char *profiles_dir = PLAYOS_NET_PROFILES_DEFAULT;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc)
            socket_path = argv[++i];
        else if (strcmp(argv[i], "--ctrl-dir") == 0 && i + 1 < argc)
            ctrl_dir = argv[++i];
        else if (strcmp(argv[i], "--profiles-dir") == 0 && i + 1 < argc)
            profiles_dir = argv[++i];
        else if (strcmp(argv[i], "--help") == 0) {
            printf("usage: playos-net [--socket PATH] [--ctrl-dir DIR] "
                   "[--profiles-dir DIR]\n");
            return 0;
        }
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);

    net_state st;
    memset(&st, 0, sizeof(st));
    st.ctrl_dir = ctrl_dir;
    st.profiles_dir = profiles_dir;

    /* The interface name is discovered, never assumed: the Ally's radio is
     * wlp6s0 (predictable naming), not wlan0. */
    if (net_discover_ifname(st.ifname, sizeof(st.ifname)) != 0) {
        net_log("WARN", "no wireless interface found under /sys/class/net");
        snprintf(st.ifname, sizeof(st.ifname), "wlan0");
    }
    net_log("INFO", "playos-net starting (ifname=%s, socket=%s)",
            st.ifname, socket_path);

    /* wpa_supplicant must be able to create its control socket here. */
    mkdir("/run", 0755);
    mkdir("/run/playos", 0755);
    mkdir(ctrl_dir, 0770);

    int srv = playos_ipc_server_create(socket_path, PLAYOS_NET_TRUSTED_GROUP);
    if (srv < 0) {
        net_log("ERROR", "cannot create %s: %s", socket_path, strerror(errno));
        return 1;
    }
    net_log("INFO", "listening on %s", socket_path);

    int clients[MAX_CLIENTS];
    for (int i = 0; i < MAX_CLIENTS; i++)
        clients[i] = -1;

    time_t next_wpa_retry = 0;

    while (!g_stop) {
        struct pollfd pfd[2 + MAX_CLIENTS];
        int slot[MAX_CLIENTS];
        int n = 0, ncli = 0;

        pfd[n].fd = srv;
        pfd[n].events = POLLIN;
        pfd[n].revents = 0;
        n++;

        int wfd = st.wpa ? wpa_event_fd(st.wpa) : -1;
        if (wfd >= 0) {
            pfd[n].fd = wfd;
            pfd[n].events = POLLIN;
            pfd[n].revents = 0;
            n++;
        }

        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (clients[i] < 0)
                continue;
            slot[ncli] = i;
            pfd[n].fd = clients[i];
            pfd[n].events = POLLIN;
            pfd[n].revents = 0;
            n++;
            ncli++;
        }

        int r = poll(pfd, (nfds_t)n, 1000);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            net_log("ERROR", "poll: %s", strerror(errno));
            break;
        }

        /* New client. */
        if (pfd[0].revents & POLLIN) {
            int cfd = playos_ipc_server_accept(srv);
            if (cfd >= 0) {
                if (playos_ipc_server_check_peer(cfd, PLAYOS_NET_TRUSTED_GROUP) != 0) {
                    net_log("WARN", "rejected peer (not root, not GID %d)",
                            PLAYOS_NET_TRUSTED_GID);
                    close(cfd);
                } else {
                    int placed = 0;
                    for (int i = 0; i < MAX_CLIENTS; i++) {
                        if (clients[i] < 0) {
                            clients[i] = cfd;
                            placed = 1;
                            break;
                        }
                    }
                    if (!placed) {
                        net_log("WARN", "client table full — dropping peer");
                        close(cfd);
                    }
                }
            }
        }

        /* wpa_supplicant events → async state changes. */
        if (wfd >= 0 && pfd[1].revents & POLLIN) {
            const char *state = wpa_poll_event(st.wpa);
            if (state) {
                char extra[64];
                snprintf(extra, sizeof(extra), "\"state\":\"%s\"", state);
                net_log("INFO", "state -> %s", state);
                for (int i = 0; i < MAX_CLIENTS; i++)
                    if (clients[i] >= 0)
                        reply(clients[i], "NetworkStateChanged", extra);
            }
        }

        /* Client requests. pfd layout: [0] = listener, [1] = wpa events (when a
         * monitor exists), then one slot per connected client — so the client
         * fds start at index 1 or 2, not a fixed 2. */
        const int client_base = (wfd >= 0) ? 2 : 1;
        for (int k = 0; k < ncli; k++) {
            int cfd = clients[slot[k]];
            if (!(pfd[client_base + k].revents & POLLIN))
                continue;

            static char frame[FRAME_MAX];
            int got = playos_ipc_frame_read(cfd, (struct playos_ipc_frame *)frame,
                                            sizeof(frame));
            if (got <= 0) {
                close(cfd);
                clients[slot[k]] = -1;
                continue;
            }

            struct playos_ipc_frame *f = (struct playos_ipc_frame *)frame;
            if (playos_ipc_frame_validate(f) != 0) {
                net_log("WARN", "bad frame from client");
                close(cfd);
                clients[slot[k]] = -1;
                continue;
            }

            struct playos_ipc_message msg;
            if (playos_ipc_message_parse(f->body, f->length, &msg) != 0) {
                net_log("WARN", "bad JSON from client");
                continue;
            }

            handle_request(&st, cfd, msg.type, msg.json_raw);
            playos_ipc_message_free(&msg);
        }

        /* Keep trying to reach wpa_supplicant; it may start after us. */
        if (!st.wpa && time(NULL) >= next_wpa_retry) {
            next_wpa_retry = time(NULL) + WPA_RETRY_SEC;
            ensure_wpa(&st);
        }
    }

    net_log("INFO", "shutting down");
    for (int i = 0; i < MAX_CLIENTS; i++)
        if (clients[i] >= 0)
            close(clients[i]);
    if (st.wpa)
        wpa_close(st.wpa);
    playos_ipc_server_close(srv, socket_path);
    return 0;
}
