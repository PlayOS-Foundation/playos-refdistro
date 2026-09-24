/*
 * profiles.c — known-network persistence for playos-net
 *
 * Profiles live in /data/config/network/<slug>.json plus a `last` pointer, so a
 * reboot can auto-connect to the most recently used network. The file holds the
 * PSK, so it is created 0600 and the PSK is never logged.
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include "playos_net.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* SSIDs are arbitrary bytes; the on-disk name is a conservative slug. */
static void slugify(const char *ssid, char *out, size_t out_sz)
{
    size_t j = 0;

    for (size_t i = 0; ssid[i] && j + 5 < out_sz; i++) {
        unsigned char c = (unsigned char)ssid[i];
        if (isalnum(c) || c == '-' || c == '_' || c == '.')
            out[j++] = (char)c;
        else
            j += (size_t)snprintf(out + j, out_sz - j, "%%%02x", c);
    }

    if (j == 0)
        snprintf(out, out_sz, "net");

    out[j] = '\0';
}

static void ensure_dir(const char *dir)
{
    /* /data is the writable tree; create /data/config/network stepwise. */
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "%s", dir);

    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/')
            continue;
        *p = '\0';
        mkdir(tmp, 0700);
        *p = '/';
    }
    mkdir(tmp, 0700);
}

/* Write via a temp file + rename so a crash mid-write cannot leave a truncated
 * profile (the same idea as playos_storage_atomic_write). */
static int write_file_0600(const char *path, const char *data)
{
    char tmp[600];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);

    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0)
        return -1;

    size_t len = strlen(data);
    ssize_t n = write(fd, data, len);
    if (n < 0 || (size_t)n != len) {
        close(fd);
        unlink(tmp);
        return -1;
    }
    if (fsync(fd) != 0) {
        close(fd);
        unlink(tmp);
        return -1;
    }
    close(fd);

    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

int profiles_save(const char *dir, const char *ssid, const char *security,
                  const char *psk)
{
    if (!dir || !ssid || !ssid[0])
        return -1;

    ensure_dir(dir);

    char slug[256];
    slugify(ssid, slug, sizeof(slug));

    char path[600];
    snprintf(path, sizeof(path), "%s/%s.json", dir, slug);

    char body[1024];
    snprintf(body, sizeof(body),
             "{\"ssid\":\"%s\",\"security\":\"%s\",\"psk\":\"%s\"}\n",
             ssid, security ? security : "wpa2", psk ? psk : "");

    if (write_file_0600(path, body) != 0)
        return -1;

    /* Point `last` at this profile for boot-time auto-connect. */
    char last[600];
    snprintf(last, sizeof(last), "%s/last", dir);
    char ptr[300];
    snprintf(ptr, sizeof(ptr), "%s.json\n", slug);
    return write_file_0600(last, ptr);
}

/* Copy the value of "key":"..." out of a small profile body. */
static int extract(const char *body, const char *key, char *out, size_t out_sz)
{
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\":\"", key);

    const char *p = strstr(body, pat);
    if (!p)
        return -1;
    p += strlen(pat);

    size_t j = 0;
    while (*p && *p != '"' && j + 1 < out_sz) {
        if (*p == '\\' && p[1])
            p++;                       /* unescape the trivial cases */
        out[j++] = *p++;
    }
    out[j] = '\0';
    return 0;
}

int profiles_load_last(const char *dir, char *ssid, size_t ssid_sz,
                       char *security, size_t sec_sz,
                       char *psk, size_t psk_sz)
{
    if (!dir)
        return -1;

    char last[600];
    snprintf(last, sizeof(last), "%s/last", dir);

    FILE *f = fopen(last, "re");
    if (!f)
        return -1;

    char name[300] = {0};
    if (!fgets(name, sizeof(name), f)) {
        fclose(f);
        return -1;
    }
    fclose(f);

    size_t n = strlen(name);
    while (n && (name[n - 1] == '\n' || name[n - 1] == '\r'))
        name[--n] = '\0';
    if (n == 0)
        return -1;

    char path[900];
    snprintf(path, sizeof(path), "%s/%s", dir, name);

    f = fopen(path, "re");
    if (!f)
        return -1;

    char body[1024];
    size_t got = fread(body, 1, sizeof(body) - 1, f);
    fclose(f);
    body[got] = '\0';

    if (extract(body, "ssid", ssid, ssid_sz) != 0)
        return -1;
    if (extract(body, "security", security, sec_sz) != 0)
        snprintf(security, sec_sz, "wpa2");
    if (extract(body, "psk", psk, psk_sz) != 0)
        psk[0] = '\0';
    return 0;
}

int net_discover_ifname(char *out, size_t out_sz)
{
    const char *base = "/sys/class/net";

    DIR *d = opendir(base);
    if (!d)
        return -1;

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;

        /* A wireless interface is the one with a `wireless` attribute — the only
         * reliable way (the Ally's is wlp6s0, not wlan0). */
        char probe[600];
        snprintf(probe, sizeof(probe), "%s/%s/wireless", base, e->d_name);
        if (access(probe, F_OK) == 0) {
            snprintf(out, out_sz, "%s", e->d_name);
            closedir(d);
            return 0;
        }
    }

    closedir(d);
    return -1;
}
