/*
 * wpa_bridge.c — wpa_supplicant control-protocol bridge for playos-net
 *
 * Thin layer over libwpa_client (wpa_ctrl): open the per-interface control
 * socket, attach an event monitor, and translate the text protocol
 * (SCAN/SCAN_RESULTS/STATUS/ADD_NETWORK/SELECT_NETWORK, CTRL-EVENT-*) into the
 * structured results the daemon puts on the wire. Nothing above this file knows
 * that wpa_supplicant speaks text.
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include "playos_net.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <wpa_ctrl.h>

#define REPLY_MAX 8192

struct playos_wpa {
    struct wpa_ctrl *ctrl;      /* command socket */
    struct wpa_ctrl *mon;       /* attached event socket */
};

/* wpa_ctrl_request does not NUL-terminate: pass size-1 and append it. */
static int cmd(struct wpa_ctrl *c, const char *text, char *reply, size_t reply_sz)
{
    size_t len = reply_sz - 1;

    if (wpa_ctrl_request(c, text, strlen(text), reply, &len, NULL) < 0)
        return -1;

    reply[len] = '\0';
    return 0;
}

playos_wpa *wpa_open(const char *ctrl_dir, const char *ifname, int *err)
{
    char path[256];
    snprintf(path, sizeof(path), "%s/%s", ctrl_dir, ifname);

    struct wpa_ctrl *c = wpa_ctrl_open(path);
    if (!c) {
        if (err)
            *err = errno;
        return NULL;
    }

    playos_wpa *w = calloc(1, sizeof(*w));
    if (!w) {
        wpa_ctrl_close(c);
        if (err)
            *err = ENOMEM;
        return NULL;
    }
    w->ctrl = c;

    /* The event monitor is a second connection: the command socket must stay
     * un-attached so requests and events never interleave on one fd. */
    w->mon = wpa_ctrl_open(path);
    if (w->mon && wpa_ctrl_attach(w->mon) != 0) {
        wpa_ctrl_close(w->mon);
        w->mon = NULL;
    }

    return w;
}

void wpa_close(playos_wpa *w)
{
    if (!w)
        return;

    if (w->mon) {
        wpa_ctrl_detach(w->mon);
        wpa_ctrl_close(w->mon);
    }
    if (w->ctrl)
        wpa_ctrl_close(w->ctrl);
    free(w);
}

int wpa_event_fd(const playos_wpa *w)
{
    if (!w || !w->mon)
        return -1;
    return wpa_ctrl_get_fd(w->mon);
}

const char *wpa_poll_event(playos_wpa *w)
{
    if (!w || !w->mon || wpa_ctrl_pending(w->mon) <= 0)
        return NULL;

    char buf[REPLY_MAX];
    size_t len = sizeof(buf) - 1;
    if (wpa_ctrl_recv(w->mon, buf, &len) < 0)
        return NULL;
    buf[len] = '\0';

    if (strstr(buf, "CTRL-EVENT-CONNECTED"))
        return "connected";
    if (strstr(buf, "CTRL-EVENT-DISCONNECTED"))
        return "disconnected";
    if (strstr(buf, "CTRL-EVENT-CONNECTING") ||
        strstr(buf, "CTRL-EVENT-ASSOC-REJECT") ||
        strstr(buf, "CTRL-EVENT-AUTH-REJECT") ||
        strstr(buf, "CTRL-EVENT-SSID-TEMP-DISABLED") ||
        strstr(buf, "CTRL-EVENT-NETWORK-NOT-FOUND"))
        return "connecting";

    return NULL;    /* SCAN-RESULTS and friends are not state changes */
}

/* Split a line on tabs, preserving empty fields (hidden SSIDs give one). */
static int split_tabs(char *line, char *fields[], int maxf)
{
    int n = 0;
    char *p = line;

    while (n < maxf) {
        fields[n++] = p;
        char *t = strchr(p, '\t');
        if (!t)
            break;
        *t = '\0';
        p = t + 1;
    }
    return n;
}

static void security_from_flags(const char *flags, char *out, size_t out_sz)
{
    if (strstr(flags, "SAE"))
        snprintf(out, out_sz, "wpa3");
    else if (strstr(flags, "WPA2") || strstr(flags, "RSN"))
        snprintf(out, out_sz, "wpa2");
    else if (strstr(flags, "WPA"))
        snprintf(out, out_sz, "wpa");
    else if (strstr(flags, "WEP"))
        snprintf(out, out_sz, "wep");
    else
        snprintf(out, out_sz, "open");
}

static void parse_scan_results(const char *body, playos_net_ap *out, int max,
                               int *count)
{
    int n = 0;
    const char *p = body;

    while (*p && n < max) {
        const char *eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p) : strlen(p);

        char line[512];
        if (len >= sizeof(line))
            len = sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = '\0';
        p = eol ? eol + 1 : p + len;

        if (line[0] == '\0' || strncmp(line, "bssid", 5) == 0)
            continue;                       /* blank or the header row */

        char *f[5];
        if (split_tabs(line, f, 5) < 5)
            continue;

        const char *sig = f[2];
        const char *flags = f[3];
        const char *ssid = f[4];
        if (ssid[0] == '\0')
            continue;                       /* hidden */

        int dbm = atoi(sig);

        /* Collapse duplicates: keep one entry per SSID, strongest signal. */
        int found = -1;
        for (int i = 0; i < n; i++) {
            if (strcmp(out[i].ssid, ssid) == 0) {
                found = i;
                break;
            }
        }

        if (found >= 0) {
            if (dbm > out[found].signal_dbm) {
                out[found].signal_dbm = dbm;
                security_from_flags(flags, out[found].security,
                                    sizeof(out[found].security));
            }
            continue;
        }

        snprintf(out[n].ssid, sizeof(out[n].ssid), "%s", ssid);
        security_from_flags(flags, out[n].security, sizeof(out[n].security));
        out[n].signal_dbm = dbm;
        n++;
    }

    *count = n;
}

int wpa_scan(playos_wpa *w, playos_net_ap *out, int max, int *count)
{
    char buf[REPLY_MAX];

    *count = 0;
    if (!w || !w->ctrl)
        return -1;

    if (cmd(w->ctrl, "SCAN", buf, sizeof(buf)) < 0)
        return -1;

    /* FAIL-BUSY just means a scan is already running — its results are what we
     * want anyway. Any other FAIL is a real error. */
    if (strncmp(buf, "FAIL", 4) == 0 && !strstr(buf, "BUSY"))
        return -1;

    for (int attempt = 0; attempt < 30; attempt++) {
        usleep(200 * 1000);

        if (cmd(w->ctrl, "SCAN_RESULTS", buf, sizeof(buf)) < 0)
            return -1;

        parse_scan_results(buf, out, max, count);
        if (*count > 0)
            return 0;
    }

    return 0;   /* nothing in range (or all hidden) — not an error */
}

/* Read `key=value` out of a STATUS/SIGNAL_POLL body. */
static int kv(const char *body, const char *key, char *out, size_t out_sz)
{
    size_t klen = strlen(key);
    const char *p = body;

    while (p && *p) {
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            const char *v = p + klen + 1;
            const char *eol = strchr(v, '\n');
            size_t len = eol ? (size_t)(eol - v) : strlen(v);
            if (len >= out_sz)
                len = out_sz - 1;
            memcpy(out, v, len);
            out[len] = '\0';
            return 0;
        }
        p = strchr(p, '\n');
        if (p)
            p++;
    }
    return -1;
}

int wpa_status(playos_wpa *w, char *state, size_t state_sz,
               char *ssid, size_t ssid_sz, char *ip, size_t ip_sz,
               int *signal_dbm)
{
    char buf[REPLY_MAX];
    char wpa_state[64] = {0};

    if (!w || !w->ctrl)
        return -1;

    if (cmd(w->ctrl, "STATUS", buf, sizeof(buf)) < 0)
        return -1;

    kv(buf, "wpa_state", wpa_state, sizeof(wpa_state));
    kv(buf, "ssid", ssid, ssid_sz);
    if (kv(buf, "ip_address", ip, ip_sz) != 0)
        ip[0] = '\0';

    if (strcmp(wpa_state, "COMPLETED") == 0)
        snprintf(state, state_sz, "connected");
    else if (strcmp(wpa_state, "SCANNING") == 0 ||
             strcmp(wpa_state, "ASSOCIATING") == 0 ||
             strcmp(wpa_state, "ASSOCIATED") == 0 ||
             strcmp(wpa_state, "AUTHENTICATING") == 0 ||
             strcmp(wpa_state, "4WAY_HANDSHAKE") == 0 ||
             strcmp(wpa_state, "GROUP_HANDSHAKE") == 0)
        snprintf(state, state_sz, "connecting");
    else
        snprintf(state, state_sz, "disconnected");

    if (signal_dbm) {
        *signal_dbm = 0;
        if (cmd(w->ctrl, "SIGNAL_POLL", buf, sizeof(buf)) == 0) {
            char rssi[16];
            if (kv(buf, "RSSI", rssi, sizeof(rssi)) == 0)
                *signal_dbm = atoi(rssi);
        }
    }

    return 0;
}

int wpa_connect(playos_wpa *w, const char *ssid, const char *psk,
                const char *security, char *reason, size_t reason_sz)
{
    char buf[REPLY_MAX];
    char line[512];
    int id;

    if (reason && reason_sz)
        reason[0] = '\0';

    if (!w || !w->ctrl || !ssid || !ssid[0]) {
        if (reason && reason_sz)
            snprintf(reason, reason_sz, "bad_request");
        return -1;
    }

    if (cmd(w->ctrl, "ADD_NETWORK", buf, sizeof(buf)) < 0 ||
        strncmp(buf, "FAIL", 4) == 0) {
        if (reason && reason_sz)
            snprintf(reason, reason_sz, "no_wpa");
        return -1;
    }
    id = atoi(buf);

    snprintf(line, sizeof(line), "SET_NETWORK %d ssid \"%s\"", id, ssid);
    if (cmd(w->ctrl, line, buf, sizeof(buf)) < 0 || strncmp(buf, "FAIL", 4) == 0)
        goto failed;

    if (!psk || !psk[0] || strcmp(security, "open") == 0) {
        snprintf(line, sizeof(line), "SET_NETWORK %d key_mgmt NONE", id);
        if (cmd(w->ctrl, line, buf, sizeof(buf)) < 0 ||
            strncmp(buf, "FAIL", 4) == 0)
            goto failed;
    } else {
        snprintf(line, sizeof(line), "SET_NETWORK %d psk \"%s\"", id, psk);
        if (cmd(w->ctrl, line, buf, sizeof(buf)) < 0 ||
            strncmp(buf, "FAIL", 4) == 0)
            goto failed;

        /* WPA3-SAE needs SAE key management; WPA2-PSK is the default otherwise. */
        const char *km = (security && strcmp(security, "wpa3") == 0)
                             ? "SAE" : "WPA-PSK";
        snprintf(line, sizeof(line), "SET_NETWORK %d key_mgmt %s", id, km);
        if (cmd(w->ctrl, line, buf, sizeof(buf)) < 0 ||
            strncmp(buf, "FAIL", 4) == 0)
            goto failed;
    }

    snprintf(line, sizeof(line), "ENABLE_NETWORK %d", id);
    if (cmd(w->ctrl, line, buf, sizeof(buf)) < 0 || strncmp(buf, "FAIL", 4) == 0)
        goto failed;

    /* SELECT_NETWORK starts the association; the result arrives as an event. */
    snprintf(line, sizeof(line), "SELECT_NETWORK %d", id);
    if (cmd(w->ctrl, line, buf, sizeof(buf)) < 0 || strncmp(buf, "FAIL", 4) == 0)
        goto failed;

    return 0;

failed:
    if (reason && reason_sz)
        snprintf(reason, reason_sz, "auth_failed");
    return -1;
}

int wpa_disconnect(playos_wpa *w)
{
    char buf[REPLY_MAX];

    if (!w || !w->ctrl)
        return -1;
    return cmd(w->ctrl, "DISCONNECT", buf, sizeof(buf));
}
