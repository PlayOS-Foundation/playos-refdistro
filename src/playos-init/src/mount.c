/*
 * playos-init/src/mount.c — Filesystem mounting and data partition discovery
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "playos-init/init.h"
#include "playos-init/mount.h"

/* ── External logging ────────────────────────────────────────────── */

void playos_log_write(struct playos_init_state *s, const char *tag,
                      const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

/* ── Mount virtual filesystems ───────────────────────────────────── */

int playos_mount_virtual(void)
{
    /* /dev — device filesystem */
    if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) != 0) {
        dprintf(STDERR_FILENO, "playos-init: mount /dev failed: %s\n",
                strerror(errno));
        return -1;
    }

    /* /proc — process information */
    if (mount("proc", "/proc", "proc", 0, NULL) != 0) {
        dprintf(STDERR_FILENO, "playos-init: mount /proc failed: %s\n",
                strerror(errno));
        return -1;
    }

    /* /sys — kernel and device information */
    if (mount("sysfs", "/sys", "sysfs", 0, NULL) != 0) {
        dprintf(STDERR_FILENO, "playos-init: mount /sys failed: %s\n",
                strerror(errno));
        return -1;
    }

    /* /run — runtime data, tmpfs */
    if (mount("tmpfs", "/run", "tmpfs", 0, "mode=0755") != 0) {
        dprintf(STDERR_FILENO, "playos-init: mount /run failed: %s\n",
                strerror(errno));
        return -1;
    }

    return 0;
}

/* ── Data partition discovery ────────────────────────────────────── */

/*
 * Search for the data partition in order:
 *   1. Partition with label "playos-data" via /dev/disk/by-label/
 *   2. Direct scan of common block devices (for systems without udev)
 *   3. GPT partition type GUID (reserved for future use)
 *   4. UUID from kernel command line: playos.data_uuid=<uuid>
 */

/*
 * Read ext4 volume label from superblock at offset 0x400.
 * The label is at offset 0x78 within the superblock (0x478 total),
 * 16 bytes, null-terminated.
 */
static int read_ext4_label(const char *device, char *label, size_t label_size)
{
    int fd = open(device, O_RDONLY);
    if (fd < 0) return -1;

    /* ext4 superblock starts at byte 1024 (0x400).
     * Magic (0xEF53) is at superblock+0x38 = 0x438.
     * Volume label (16 bytes) is at superblock+0x78 = 0x478. */

    /* Check magic at offset 0x438 */
    if (lseek(fd, 0x438, SEEK_SET) != 0x438) {
        close(fd);
        return -1;
    }
    unsigned char magic_buf[2];
    if (read(fd, magic_buf, 2) != 2) {
        close(fd);
        return -1;
    }
    if (magic_buf[0] != 0x53 || magic_buf[1] != 0xEF) {
        close(fd);
        return -1;
    }

    /* Read label at offset 0x478 */
    if (lseek(fd, 0x478, SEEK_SET) != 0x478) {
        close(fd);
        return -1;
    }
    ssize_t n = read(fd, label, label_size - 1);
    close(fd);
    if (n <= 0) return -1;

    label[n] = '\0';
    return 0;
}

static int find_data_partition(char *device_path, size_t path_size)
{
    /* Try up to 10 times with increasing delays (100ms → 1000ms)
     * because block device detection may be asynchronous even with
     * built-in virtio-blk. Total max wait: ~5s. */
    for (int attempt = 0; attempt < 10; attempt++) {
        if (attempt > 0) {
            usleep(attempt * 100000); /* 100ms, 200ms, 300ms... */
        }

        /* Strategy 1: Label "playos-data" via udev symlinks */
        const char *label_path = "/dev/disk/by-label/playos-data";
        if (access(label_path, F_OK) == 0) {
            ssize_t len = readlink(label_path, device_path, path_size - 1);
            if (len > 0) {
                device_path[len] = '\0';
                dprintf(STDERR_FILENO,
                        "playos-init: data partition by label: %s\n",
                        device_path);
                return 0;
            }
        }

        /* Strategy 2: Direct scan of common block devices (no udev) */
        const char *candidates[] = {
            "/dev/vda", "/dev/vdb", "/dev/sda", "/dev/sdb",
            "/dev/vda1", "/dev/sda1",
            NULL
        };
        for (const char **c = candidates; *c; c++) {
            if (access(*c, F_OK) != 0) continue;
            char label[32] = {0};
            if (read_ext4_label(*c, label, sizeof(label)) == 0) {
                if (strcmp(label, "playos-data") == 0) {
                    snprintf(device_path, path_size, "%s", *c);
                    dprintf(STDERR_FILENO,
                            "playos-init: data partition by scan: %s\n",
                            device_path);
                    return 0;
                }
            }
        }

        /* Strategy 3: Scan devices from /proc/partitions */
        FILE *parts = fopen("/proc/partitions", "r");
        if (parts) {
            char line[256];
            /* Skip header lines */
            fgets(line, sizeof(line), parts);
            fgets(line, sizeof(line), parts);
            while (fgets(line, sizeof(line), parts)) {
                char name[64] = {0};
                /* Format: major minor #blocks name */
                if (sscanf(line, "%*d %*d %*d %63s", name) == 1) {
                    char dev_path[128];
                    snprintf(dev_path, sizeof(dev_path), "/dev/%s", name);
                    if (access(dev_path, F_OK) != 0) continue;
                    char label[32] = {0};
                    if (read_ext4_label(dev_path, label, sizeof(label)) == 0) {
                        if (strcmp(label, "playos-data") == 0) {
                            snprintf(device_path, path_size, "%s", dev_path);
                            fclose(parts);
                            dprintf(STDERR_FILENO,
                                    "playos-init: data partition by proc scan: %s\n",
                                    device_path);
                            return 0;
                        }
                    }
                }
            }
            fclose(parts);
        }
    }

    /* Strategy 4: GPT partition type GUID (placeholder) */
    /* TODO: iterate /dev/disk/by-partuuid/ for the PlayOS data GUID */

    /* Strategy 5: Kernel command line */
    FILE *cmdline = fopen("/proc/cmdline", "r");
    if (cmdline) {
        char buf[4096] = {0};
        if (fgets(buf, sizeof(buf), cmdline)) {
            char *p = strstr(buf, "playos.data_uuid=");
            if (p) {
                p += strlen("playos.data_uuid=");
                char *end = strchrnul(p, ' ');
                int uuid_len = (int)(end - p);
                if (uuid_len > 0 && uuid_len < 64) {
                    snprintf(device_path, path_size,
                             "/dev/disk/by-uuid/%.*s", uuid_len, p);
                    if (access(device_path, F_OK) == 0) {
                        fclose(cmdline);
                        dprintf(STDERR_FILENO,
                                "playos-init: data partition by UUID: %s\n",
                                device_path);
                        return 0;
                    }
                }
            }
        }
        fclose(cmdline);
    }

    return -1;
}

int playos_mount_data(struct playos_init_state *state)
{
    (void)state;

    char device_path[256] = {0};

    if (find_data_partition(device_path, sizeof(device_path)) != 0) {
        dprintf(STDERR_FILENO,
                "playos-init: data partition not found "
                "(label=playos-data, cmdline, GPT GUID)\n");
        return -1;
    }

    /* Create mount point */
    mkdir("/data", 0755);

    /* Mount the data partition (ext4 assumed, read-write) */
    if (mount(device_path, "/data", "ext4", 0, NULL) != 0) {
        /* Try common filesystems */
        if (mount(device_path, "/data", "vfat", 0, NULL) != 0) {
            if (mount(device_path, "/data", "auto", 0, NULL) != 0) {
                dprintf(STDERR_FILENO,
                        "playos-init: mount /data failed: %s\n",
                        strerror(errno));
                return -1;
            }
        }
    }

    dprintf(STDERR_FILENO, "playos-init: /data mounted from %s\n", device_path);
    return 0;
}

/* ── First-boot directories ──────────────────────────────────────── */

int playos_data_create_dirs(void)
{
    const char *dirs[] = {
        "/data/games",
        "/data/saves",
        "/data/system",
        "/data/log",
        NULL
    };

    for (const char **d = dirs; *d; d++) {
        if (mkdir(*d, 0755) != 0 && errno != EEXIST) {
            dprintf(STDERR_FILENO,
                    "playos-init: mkdir %s failed: %s\n",
                    *d, strerror(errno));
            return -1;
        }
    }

    return 0;
}

/* ── Boot stage marker ───────────────────────────────────────────── */

int playos_boot_stage_write(enum playos_boot_stage stage)
{
    /* Ensure /run/playos exists */
    mkdir("/run/playos", 0755);

    int fd = open("/run/playos/boot-stage",
                  O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        return -1;

    const char *stages[] = {
        [BOOT_STAGE_START]          = "start",
        [BOOT_STAGE_MOUNTS]         = "mounts",
        [BOOT_STAGE_DATA_DISCOVERY] = "data_discovery",
        [BOOT_STAGE_DATA_MOUNTED]   = "data_mounted",
        [BOOT_STAGE_IPC_READY]      = "ipc_ready",
        [BOOT_STAGE_COMPOSITOR]     = "compositor",
        [BOOT_STAGE_READY]          = "ready",
        [BOOT_STAGE_RECOVERY]       = "recovery",
    };

    const char *name = (stage < sizeof(stages)/sizeof(stages[0]) && stages[stage])
                       ? stages[stage] : "unknown";

    dprintf(fd, "%s\n", name);
    close(fd);
    return 0;
}
