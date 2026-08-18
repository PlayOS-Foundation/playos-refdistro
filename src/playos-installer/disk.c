/**
 * disk.c — PlayOS installer disk enumeration
 *
 * Reads /sys/block and /proc/partitions without relying on udev, so the
 * installer works on a minimal initramfs where /dev/disk/by-* may not exist.
 *
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <errno.h>

#include "disk.h"

/* ── sysfs helpers ─────────────────────────────────────────────────────── */

static int
read_str_file(const char *path, char *out, size_t outsz)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    if (!fgets(out, (int)outsz, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);

    size_t len = strlen(out);
    while (len > 0 && (out[len - 1] == '\n' || out[len - 1] == '\r' ||
                       out[len - 1] == ' '  || out[len - 1] == '\t'))
        out[--len] = '\0';
    return 0;
}

static int
read_ull_file(const char *path, unsigned long long *out)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    if (fscanf(f, "%llu", out) != 1) {
        fclose(f);
        return -1;
    }
    fclose(f);
    return 0;
}

static int
read_int_file(const char *path, int *out)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    if (fscanf(f, "%d", out) != 1) {
        fclose(f);
        return -1;
    }
    fclose(f);
    return 0;
}

/* Whole-disk names we never want to treat as install targets or payload
 * candidates: loop devices, ram disks, device-mapper, software RAID and
 * optical drives. */
static int
is_ignored_block_dev(const char *name)
{
    static const char *const prefixes[] = {
        "loop", "ram", "zram", "dm-", "md", "sr", "fd", NULL
    };
    for (int i = 0; prefixes[i]; i++) {
        if (strncmp(name, prefixes[i], strlen(prefixes[i])) == 0)
            return 1;
    }
    return 0;
}

/* ── partition listing ─────────────────────────────────────────────────── */

int
playos_disk_list_partitions(const char *device, char (*names)[64], int max_names)
{
    if (!device || !names || max_names <= 0)
        return 0;

    FILE *f = fopen("/proc/partitions", "r");
    if (!f)
        return 0;

    char line[256];
    size_t devlen = strlen(device);
    int n = 0;

    while (n < max_names && fgets(line, sizeof(line), f)) {
        char name[64];
        if (sscanf(line, "%*u %*u %*llu %63s", name) != 1)
            continue;
        if (strncmp(name, device, devlen) != 0)
            continue;
        if (strlen(name) <= devlen)
            continue;
        snprintf(names[n], 64, "%s", name);
        n++;
    }

    fclose(f);
    return n;
}

/* ── install-target enumeration ────────────────────────────────────────── */

int
playos_disk_enumerate(struct playos_disk **out, int *count)
{
    *out = NULL;
    *count = 0;

    DIR *dir = opendir("/sys/block");
    if (!dir)
        return -1;

    struct playos_disk *disks = NULL;
    int n = 0;
    int cap = 0;

    struct dirent *e;
    while ((e = readdir(dir)) != NULL) {
        const char *name = e->d_name;
        if (name[0] == '.')
            continue;
        if (is_ignored_block_dev(name))
            continue;

        char path[320];
        unsigned long long size = 0;
        snprintf(path, sizeof(path), "/sys/block/%s/size", name);
        if (read_ull_file(path, &size) != 0 || size == 0)
            continue;

        int removable = 0;
        snprintf(path, sizeof(path), "/sys/block/%s/removable", name);
        read_int_file(path, &removable);

        /* The boot USB is removable; installation targets are fixed disks. */
        if (removable != 0)
            continue;

        char model[256];
        snprintf(path, sizeof(path), "/sys/block/%s/device/model", name);
        if (read_str_file(path, model, sizeof(model)) != 0 || model[0] == '\0') {
            snprintf(path, sizeof(path), "/sys/block/%s/device/name", name);
            if (read_str_file(path, model, sizeof(model)) != 0 || model[0] == '\0')
                snprintf(model, sizeof(model), "%s", name);
        }

        if (n == cap) {
            int newcap = cap ? cap * 2 : 4;
            struct playos_disk *tmp =
                realloc(disks, (size_t)newcap * sizeof(*tmp));
            if (!tmp) {
                free(disks);
                closedir(dir);
                return -1;
            }
            disks = tmp;
            cap = newcap;
        }

        struct playos_disk *d = &disks[n++];
        memset(d, 0, sizeof(*d));
        snprintf(d->device, sizeof(d->device), "%s", name);
        snprintf(d->path, sizeof(d->path), "/dev/%s", name);
        snprintf(d->model, sizeof(d->model), "%s", model);
        d->size_bytes = size * 512ULL;
        d->removable = removable;
        d->partitions = 0;

        char parts[256][64];
        d->partitions = playos_disk_list_partitions(name, parts, 256);
    }

    closedir(dir);

    *out = disks;
    *count = n;
    return 0;
}

void
playos_disk_free(struct playos_disk *disks, int count)
{
    (void)count;
    free(disks);
}
