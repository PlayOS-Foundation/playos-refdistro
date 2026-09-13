/**
 * main.c — PlayOS installer (trusted, internal-disk) state machine
 *
 * A Raylib client, pre-spawned by playos-init when the kernel command line
 * carries playos.mode=install. It registers itself as the trusted shell role
 * so the compositor maps it fullscreen, then walks the user through:
 *   DISCOVERY  pick the fixed internal disk to install to
 *   CONFIRM    hold A for 3 seconds to confirm (destructive)
 *   INSTALLING GPT layout + filesystems + system-A image + EFI
 *   SUCCESS / ERROR
 *
 * The installer is intentionally self-contained and does not link
 * libplayos-trusted/libplayos: it uses raw syscalls (mount, reboot) and the
 * standard mkfs.*, blockdev and efibootmgr tools.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 199309L
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif

#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <ctype.h>

#include <wayland-client.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/reboot.h>

/* raylib.h must be included before <linux/input.h>: the kernel headers
 * #define KEY_* macros that collide with raylib's KeyboardKey enum. */
#include "raylib.h"

#include <linux/input.h>
#include <linux/input-event-codes.h>

#include "playos-v1-client-protocol.h"
#include "disk.h"
#include "format.h"
#include "efi.h"

/* ── installer diagnostics ───────────────────────────────────────────────
 * The installer runs while the boot medium's playos-data partition is mounted
 * at /data, so we append a plain-text log there. This makes failures
 * diagnosable without a serial console on the Ally. Never fail the install
 * because logging is unavailable. */
static FILE *installer_log;

static void
installer_log_open(void)
{
    if (installer_log)
        return;
    mkdir("/data/log", 0755);
    installer_log = fopen("/data/log/installer.log", "a");
    if (!installer_log)
        installer_log = fopen("/tmp/installer.log", "a");
}

static void
installer_logf(const char *fmt, ...)
{
    if (!installer_log)
        installer_log_open();
    if (!installer_log)
        return;

    va_list ap;
    va_start(ap, fmt);
    vfprintf(installer_log, fmt, ap);
    va_end(ap);
    fputc('\n', installer_log);
    fflush(installer_log);
}

/* ── Raylib PlayOS backend accessors ─────────────────────────────────────
 * Declared here because the vendored raylib builds the PlayOS backend
 * (rcore_playos.c) without exporting these through a public header. The
 * installer registers as the shell role so the compositor maps it; it never
 * calls set_surface (there is no shell accessor, matching the real shell). */
extern struct playos_manager_v1 *platform_get_playos_manager(void);
extern void platform_playos_flush(void);
extern int  platform_playos_preconnect(void);

/* ── Direct evdev controller input ───────────────────────────────────────
 * The installer is trusted, so it reads the controller directly. It only
 * needs A (select/confirm), B (back/power-off) and D-pad up/down (cursor). */

#define BITS_PER_LONG  (sizeof(unsigned long) * 8)
#define NBITS(x)       (((unsigned long)(x) / BITS_PER_LONG) + 1)
#define EVDEV_BITS(x)  NBITS(x)
#define TEST_BIT(bit, array) \
    (((array)[(unsigned long)(bit) / BITS_PER_LONG] >> \
      ((unsigned long)(bit) % BITS_PER_LONG)) & 1)

static int
is_gamepad_device(int fd)
{
    unsigned long abs_bits[EVDEV_BITS(ABS_MAX)] = {0};
    unsigned long key_bits[EVDEV_BITS(KEY_MAX)] = {0};

    if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits) < 0)
        return 0;
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits) < 0)
        return 0;

    if (!TEST_BIT(ABS_X, abs_bits) || !TEST_BIT(ABS_Y, abs_bits) ||
        !TEST_BIT(ABS_RX, abs_bits) || !TEST_BIT(ABS_RY, abs_bits))
        return 0;
    if (!TEST_BIT(BTN_SOUTH, key_bits))
        return 0;

    return 1;
}

static int
find_gamepad(void)
{
    DIR *dir = opendir("/dev/input");
    if (!dir)
        return -1;

    int best_fd = -1;
    struct dirent *entry;

    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "event", 5) != 0)
            continue;

        char path[320];
        snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name);

        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0)
            continue;
        if (!is_gamepad_device(fd)) {
            close(fd);
            continue;
        }

        char name[256] = {0};
        ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);

        /* Prefer Xbox/ASUS controllers (ROG Ally) over generic HID. */
        if (strstr(name, "Xbox") || strstr(name, "xbox") ||
            strstr(name, "Microsoft") || strstr(name, "ASUE") ||
            strstr(name, "ASUS") || strstr(name, "ROG Ally") ||
            strstr(name, "Gamepad")) {
            closedir(dir);
            return fd;
        }

        if (best_fd < 0)
            best_fd = fd;
        else
            close(fd);
    }

    closedir(dir);
    return best_fd;
}

struct input_state {
    int a_press;   /* press edge this frame */
    int b_press;
    int up_press;
    int down_press;
    int a_down;    /* persistent hold state (from EV_KEY value != 0) */
};

static void
poll_input(int fd, struct input_state *st)
{
    st->a_press = 0;
    st->b_press = 0;
    st->up_press = 0;
    st->down_press = 0;

    if (fd < 0)
        return;

    struct input_event ev;
    while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
        if (ev.type != EV_KEY)
            continue;

        if (ev.code == BTN_SOUTH) {
            if (ev.value != 0)
                st->a_down = 1;
            else
                st->a_down = 0;
            if (ev.value == 1)
                st->a_press = 1;
        } else if (ev.value == 1) {
            /* press edge only for the rest */
            if (ev.code == BTN_EAST)
                st->b_press = 1;
            else if (ev.code == BTN_DPAD_UP)
                st->up_press = 1;
            else if (ev.code == BTN_DPAD_DOWN)
                st->down_press = 1;
        }
    }
}

/* ── payload mount (installer USB) ───────────────────────────────────────
 * Finds the removable boot medium carrying rootfs.squashfs + BOOTX64.EFI and
 * mounts its playos-a partition read-only at /mnt/payload. Prefers the
 * by-label node, then falls back to scanning /sys/block for removable disks. */

static int
read_int_file(const char *path, int *out)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    int r = fscanf(f, "%d", out) == 1 ? 0 : -1;
    fclose(f);
    return r;
}

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

static int
payload_files_present(void)
{
    return access("/mnt/payload/rootfs.squashfs", R_OK) == 0 &&
           access("/mnt/payload/BOOTX64.EFI", R_OK) == 0;
}

static int
mount_payload_try(const char *devpath)
{
    if (mount(devpath, "/mnt/payload", "ext2", MS_RDONLY, NULL) == 0)
        return 0;
    if (mount(devpath, "/mnt/payload", "ext4", MS_RDONLY, NULL) == 0)
        return 0;
    return -1;
}

static int
find_and_mount_payload(char *mount_path, size_t mount_len)
{
    (void)mkdir("/mnt/payload", 0755);
    (void)mkdir("/mnt/efi", 0755);
    snprintf(mount_path, mount_len, "/mnt/payload");

    /* Fast path: udev/device-mapper label node when present. */
    if (mount_payload_try("/dev/disk/by-label/playos-a") == 0) {
        if (payload_files_present())
            return 0;
        (void)umount("/mnt/payload");
    }

    /* Slow path: walk /sys/block looking for removable whole disks. */
    DIR *dir = opendir("/sys/block");
    if (!dir)
        return -1;

    struct dirent *e;
    while ((e = readdir(dir)) != NULL) {
        const char *name = e->d_name;
        if (name[0] == '.')
            continue;
        if (is_ignored_block_dev(name))
            continue;

        char path[320];
        int removable = 0;
        snprintf(path, sizeof(path), "/sys/block/%s/removable", name);
        if (read_int_file(path, &removable) != 0 || removable == 0)
            continue;

        char parts[256][64];
        int nparts = playos_disk_list_partitions(name, parts, 256);
        for (int i = 0; i < nparts; i++) {
            char devpath[128];
            snprintf(devpath, sizeof(devpath), "/dev/%s", parts[i]);
            if (mount_payload_try(devpath) != 0)
                continue;
            if (payload_files_present()) {
                closedir(dir);
                return 0;
            }
            (void)umount("/mnt/payload");
        }
    }

    closedir(dir);
    return -1;
}

/* S13.7: mount the boot medium's playos-data read-only at /mnt/payload-data.
 * The live/installer session's /data is unmounted by init before the installer
 * is spawned, so the dev SSH key must be read from the USB's own data
 * partition instead of /data. Returns 0 and leaves the mount in place (caller
 * unmounts), or -1 when no playos-data with a key can be found. */
static int
find_and_mount_payload_data(char *mount_path, size_t mount_len)
{
    (void)mkdir("/mnt/payload-data", 0755);
    snprintf(mount_path, mount_len, "/mnt/payload-data");

    /* 1) Same disk as the already-mounted payload (playos-a). This is the
     * reliable path: it works even when the firmware reports removable=0
     * (e.g. QEMU usb-storage), unlike a pure /sys/block/removable filter. */
    char payload_dev[128] = {0};
    FILE *mntf = fopen("/proc/mounts", "r");
    if (mntf) {
        char line[512];
        while (fgets(line, sizeof(line), mntf)) {
            char src[128] = {0}, mnt[128] = {0};
            if (sscanf(line, "%127s %127s %*s %*s %*d %*d", src, mnt) == 2 &&
                strcmp(mnt, "/mnt/payload") == 0) {
                snprintf(payload_dev, sizeof(payload_dev), "%s", src);
                break;
            }
        }
        fclose(mntf);
    }
    if (payload_dev[0] && strncmp(payload_dev, "/dev/disk/by-label/", 19) == 0) {
        char resolved[256] = {0};
        ssize_t rl = readlink(payload_dev, resolved, sizeof(resolved) - 1);
        if (rl > 0) {
            resolved[rl] = '\0';
            const char *base = strrchr(resolved, '/');
            base = base ? base + 1 : resolved;
            snprintf(payload_dev, sizeof(payload_dev), "/dev/%s", base);
        }
    }
    if (payload_dev[0]) {
        char disk[128];
        size_t dlen = strlen(payload_dev);
        while (dlen > 0 && isdigit((unsigned char)payload_dev[dlen - 1]))
            dlen--;
        if (dlen > 0 && payload_dev[dlen - 1] == 'p')
            dlen--;
        if (dlen > 0 && dlen < sizeof(disk)) {
            memcpy(disk, payload_dev, dlen);
            disk[dlen] = '\0';
            const char *dname = strrchr(disk, '/');
            dname = dname ? dname + 1 : disk;
            char parts[256][64];
            int nparts = playos_disk_list_partitions(dname, parts, 256);
            fprintf(stdout, "AUTO: payload-data: payload on %s, disk %s (%d parts)\n",
                    payload_dev, dname, nparts);
            for (int i = 0; i < nparts; i++) {
                char devpath[128];
                snprintf(devpath, sizeof(devpath), "/dev/%s", parts[i]);
                if (strcmp(devpath, payload_dev) == 0)
                    continue; /* playos-a itself, not data */
                errno = 0;
                int mrc = mount(devpath, "/mnt/payload-data", "ext4", MS_RDONLY, NULL);
                if (mrc != 0)
                    mrc = mount(devpath, "/mnt/payload-data", "ext2", MS_RDONLY, NULL);
                fprintf(stdout, "AUTO: payload-data: try %s mount rc=%d errno=%s\n",
                        devpath, mrc, strerror(errno));
                if (mrc != 0)
                    continue;
                if (access("/mnt/payload-data/ssh/authorized_keys", R_OK) == 0) {
                    fprintf(stdout, "AUTO: payload-data: key found on %s\n", devpath);
                    return 0;
                }
                fprintf(stdout, "AUTO: payload-data: no key on %s\n", devpath);
                (void)umount("/mnt/payload-data");
            }
        }
    }

    /* 2) Fast path: by-label playos-data on a removable disk (real HW). */
    if (access("/dev/disk/by-label/playos-data", R_OK) == 0) {
        char resolved[256] = {0};
        ssize_t rl = readlink("/dev/disk/by-label/playos-data", resolved,
                              sizeof(resolved) - 1);
        if (rl > 0) {
            resolved[rl] = '\0';
            const char *base = strrchr(resolved, '/');
            base = base ? base + 1 : resolved;
            char devtmp[256];
            snprintf(devtmp, sizeof(devtmp), "/dev/%s", base);
            char disk[128];
            size_t len = strlen(devtmp);
            fprintf(stdout, "AUTO: payload-data: by-label resolves to %s\n",
                    devtmp);
            while (len > 0 && isdigit((unsigned char)devtmp[len - 1]))
                len--;
            if (len > 0 && devtmp[len - 1] == 'p')
                len--;
            if (len > 0 && len < sizeof(disk)) {
                memcpy(disk, devtmp, len);
                disk[len] = '\0';
                const char *dname = strrchr(disk, '/');
                dname = dname ? dname + 1 : disk;
                char rb[192];
                snprintf(rb, sizeof(rb), "/sys/block/%s/removable", dname);
                int removable = 0;
                if (read_int_file(rb, &removable) == 0 && removable == 1) {
                    if (mount("/dev/disk/by-label/playos-data",
                              "/mnt/payload-data", "ext4", MS_RDONLY, NULL) == 0 ||
                        mount("/dev/disk/by-label/playos-data",
                              "/mnt/payload-data", "ext2", MS_RDONLY, NULL) == 0)
                        return 0;
                }
            }
        }
    }

    /* 3) Fallback: scan removable disks' partitions for a playos-data with the
     * dev SSH seed directory. */
    DIR *dir = opendir("/sys/block");
    if (!dir)
        return -1;
    struct dirent *e;
    int found = 0;
    while (!found && (e = readdir(dir)) != NULL) {
        const char *name = e->d_name;
        if (name[0] == '.')
            continue;
        if (is_ignored_block_dev(name))
            continue;
        char rb[192];
        snprintf(rb, sizeof(rb), "/sys/block/%s/removable", name);
        int removable = 0;
        if (read_int_file(rb, &removable) != 0 || removable == 0)
            continue;
        char parts[256][64];
        int nparts = playos_disk_list_partitions(name, parts, 256);
        fprintf(stdout, "AUTO: payload-data: removable disk %s has %d partitions\n",
                name, nparts);
        for (int i = 0; i < nparts; i++) {
            char devpath[128];
            snprintf(devpath, sizeof(devpath), "/dev/%s", parts[i]);
            if (mount(devpath, "/mnt/payload-data", "ext4", MS_RDONLY, NULL) != 0 &&
                mount(devpath, "/mnt/payload-data", "ext2", MS_RDONLY, NULL) != 0) {
                fprintf(stdout, "AUTO: payload-data: mount %s failed: %s\n",
                        devpath, strerror(errno));
                continue;
            }
            fprintf(stdout, "AUTO: payload-data: mounted %s\n", devpath);
            if (access("/mnt/payload-data/ssh/authorized_keys", R_OK) == 0) {
                fprintf(stdout, "AUTO: payload-data: key found on %s\n", devpath);
                found = 1;
                break;
            }
            (void)umount("/mnt/payload-data");
        }
    }
    closedir(dir);
    if (!found)
        fprintf(stdout, "AUTO: payload-data: no playos-data with key found\n");
    return found ? 0 : -1;
}

/* ── installer state machine ───────────────────────────────────────────── */

enum installer_mode {
    MODE_DISCOVERY,
    MODE_CONFIRM,
    MODE_INSTALLING,
    MODE_SUCCESS,
    MODE_ERROR,
};

static const char *const STEP_NAMES[8] = {
    "Create GPT", "Format ESP", "Write system A", "Reserve system B",
    "Format misc", "Format data", "Write EFI", "Sync"
};

struct installer {
    enum installer_mode mode;
    struct playos_disk *disks;
    int  disk_count;
    int  cursor;
    int  confirm_progress;
    int  step_index;
    int  step_error;          /* -1 when none, else the failing step index */
    char step_name[64];
    char err_buf[512];
    char payload_mount[64];
    int  payload_ok;
    int  evdev_fd;
    double splash_start;          /* S14-T10: fullscreen splash covers handoff */
    struct input_state input;
};

static int
run_install_step(struct installer *st)
{
    const char *dev = st->disks[st->cursor].device;
    char *err = st->err_buf;
    size_t errlen = sizeof(st->err_buf);
    int rc = 0;

    if (st->step_index < 0 || st->step_index >= 8) {
        snprintf(err, errlen, "invalid step index %d", st->step_index);
        st->step_error = -1;
        st->mode = MODE_ERROR;
        return -1;
    }

    snprintf(st->step_name, sizeof(st->step_name), "%s",
             STEP_NAMES[st->step_index]);

    installer_logf("installer step %d/8 %s: begin (target=%s)",
                   st->step_index, st->step_name, dev);

    switch (st->step_index) {
    case 0:
        /* Make the target free first: a partition of it staying mounted (the
         * ESP is mounted as /EFI by init on a live session) makes mkfs refuse
         * the format and the kernel refuse to re-read the partition table. */
        if (playos_format_release_target(dev, err, errlen) != 0) {
            rc = -1;
            break;
        }
        installer_logf("installer: target %s is free of mounts", dev);
        rc = playos_format_partition_disk(dev, err, errlen);
        break;
    case 1: rc = playos_format_mkfs_fat(dev, 1, "ESP", err, errlen); break;
    case 2: rc = playos_format_write_image(dev, 2, "/mnt/payload/rootfs.squashfs",
                                           err, errlen); break;
    case 3: rc = 0; break; /* system B is reserved for a future OTA */
    case 4: rc = playos_format_mkfs_ext4(dev, 4, "misc", err, errlen); break;
    case 5:
        rc = playos_format_mkfs_ext4(dev, 5, "playos-data", err, errlen);
        if (rc == 0) {
            const char *src = "/data/ssh/authorized_keys";
            int key_present = (access(src, R_OK) == 0);
            char payload_key[192] = {0};
            int payload_data_mounted = 0;

            /* /data is unmounted by init before the installer spawns, so the
             * live session's key is not visible here. init preserves it at
             * /tmp/playos-install-authorized_keys before the unmount. */
            if (!key_present &&
                access("/tmp/playos-install-authorized_keys", R_OK) == 0) {
                src = "/tmp/playos-install-authorized_keys";
                key_present = 1;
            }

            /* Last resort: mount the boot medium's own playos-data. */
            if (!key_present) {
                char pd_mount[64];
                if (find_and_mount_payload_data(pd_mount, sizeof(pd_mount)) == 0) {
                    snprintf(payload_key, sizeof(payload_key),
                             "/mnt/payload-data/ssh/authorized_keys");
                    if (access(payload_key, R_OK) == 0) {
                        src = payload_key;
                        key_present = 1;
                        payload_data_mounted = 1;
                    }
                }
            }

            fprintf(stdout, "AUTO: payload-data: step5 src=%s key_present=%d\n",
                    src, key_present);
            rc = playos_format_seed_ssh_keys(dev, 5, src, err, errlen);
            installer_logf("installer step 5/8 Format data: ssh key source %s, seed rc=%d",
                           key_present ? "present" : "absent", rc);
            if (payload_data_mounted)
                (void)umount("/mnt/payload-data");
        }
        break;
    case 6: rc = playos_efi_write(dev, st->payload_mount, err, errlen); break;
    case 7: playos_format_sync(); rc = 0; break;
    default: rc = -1; break;
    }

    if (rc != 0) {
        installer_logf("installer step %d/8 %s: FAILED: %s",
                       st->step_index, st->step_name, err);
        st->step_error = st->step_index;
        st->mode = MODE_ERROR;
        return -1;
    }

    installer_logf("installer step %d/8 %s: ok",
                   st->step_index, st->step_name);

    st->step_index++;
    if (st->step_index >= 8)
        st->mode = MODE_SUCCESS;
    return 0;
}

static const char *
mode_title(enum installer_mode mode)
{
    switch (mode) {
    case MODE_DISCOVERY: return "Select install target";
    case MODE_CONFIRM:   return "Confirm installation";
    case MODE_INSTALLING:return "Installing PlayOS";
    case MODE_SUCCESS:   return "Installation complete";
    case MODE_ERROR:     return "Installation failed";
    }
    return "";
}

/* ── drawing ───────────────────────────────────────────────────────────── */

/* S14 follow-up: the installer looks like the shell it was launched from.
 * Same font (Silkscreen), same palette (navy background, orange accent,
 * green success), same 15% content column and the same hint placement - so the
 * handoff reads as a screen change inside one product instead of a different
 * app starting up on a black background. */

#define CLR_BG     ((Color){15, 31, 56, 255})
#define CLR_TRACK  ((Color){26, 44, 72, 255})
#define CLR_ACCENT ((Color){214, 107, 0, 255})
#define CLR_TEXT   ((Color){235, 235, 242, 255})
#define CLR_DIM    ((Color){150, 152, 173, 255})
#define CLR_DONE   ((Color){77, 217, 122, 255})
#define CLR_WARN   ((Color){255, 107, 107, 255})

static Font g_ui_font = { 0 };

static void
load_ui_font(void)
{
    static const char *candidates[] = {
        "/usr/share/playos-shell/assets/Silkscreen-Regular.ttf",
        "assets/Silkscreen-Regular.ttf",
        "Silkscreen-Regular.ttf",
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if (FileExists(candidates[i])) {
            g_ui_font = LoadFontEx(candidates[i], 64, NULL, 95);
            if (g_ui_font.texture.id > 0)
                return;
        }
    }
    fprintf(stderr, "playos-installer: UI font not found - using default\n");
}

static Font ui_font(void)
{
    return g_ui_font.texture.id ? g_ui_font : GetFontDefault();
}

static float
ui_text_w(const char *text, float size)
{
    return MeasureTextEx(ui_font(), text, size, 1.0f).x;
}

static void
ui_text(const char *text, float x, float y, float size, Color c)
{
    DrawTextEx(ui_font(), text, (Vector2){x, y}, size, 1.0f, c);
}

static void
ui_text_centered(const char *text, float y, float size, Color c)
{
    ui_text(text, ((float)GetScreenWidth() - ui_text_w(text, size)) * 0.5f,
            y, size, c);
}

static void
ui_bar(float x, float y, float w, float h, float frac, Color fill)
{
    if (frac < 0.0f)
        frac = 0.0f;
    if (frac > 1.0f)
        frac = 1.0f;
    DrawRectangle((int)x, (int)y, (int)w, (int)h, CLR_TRACK);
    if (frac > 0.0f)
        DrawRectangle((int)x, (int)y, (int)(w * frac), (int)h, fill);
}

/* Long installer errors (mount failures, mkfs stderr) are wrapped instead of
 * running off the screen. */
static void
ui_text_wrapped(const char *text, float x, float y, float size, float max_w,
                Color c, int max_lines)
{
    char line[128];
    size_t len = 0;
    int lines = 0;

    for (const char *p = text; *p && lines < max_lines; p++) {
        if (len + 1 >= sizeof(line)) {
            line[len] = '\0';
            ui_text(line, x, y, size, c);
            y += size * 1.6f;
            len = 0;
            lines++;
            if (lines >= max_lines)
                break;
        }
        line[len++] = *p;
        if (len >= (size_t)(max_w / (size * 0.55f))) {
            line[len] = '\0';
            ui_text(line, x, y, size, c);
            y += size * 1.6f;
            len = 0;
            lines++;
        }
    }
    if (len > 0 && lines < max_lines) {
        line[len] = '\0';
        ui_text(line, x, y, size, c);
    }
}

static void
draw_ui(struct installer *st)
{
    int sw = GetScreenWidth();
    int sh = GetScreenHeight();
    float content_x = (float)sw * 0.15f;
    float content_w = (float)sw - content_x * 2.0f;
    float title_size = (float)sh * 0.045f;
    float body_size = (float)sh * 0.026f;
    float hint_size = (float)sh * 0.020f;
    float hint_y = (float)sh - hint_size * 3.5f;

    BeginDrawing();
    ClearBackground(CLR_BG);

    /* Brief fullscreen splash so the handoff never shows a gap between the
     * shell's last frame and the installer's first. */
    if (GetTime() - st->splash_start < 0.8) {
        ui_text_centered("PlayOS", (float)sh * 0.40f, (float)sh * 0.10f,
                         CLR_TEXT);
        ui_text_centered("Preparing installer", (float)sh * 0.56f, body_size,
                         CLR_DIM);
        EndDrawing();
        return;
    }

    ui_text_centered("Install PlayOS", (float)sh * 0.05f, title_size, CLR_TEXT);
    ui_text_centered(mode_title(st->mode), (float)sh * 0.115f, body_size,
                     CLR_DIM);

    switch (st->mode) {
    case MODE_DISCOVERY: {
        if (st->disk_count == 0) {
            ui_text_centered("No suitable internal disk found", (float)sh * 0.28f,
                             body_size, CLR_TEXT);
            ui_text_centered("Attach an internal NVMe/SATA disk and restart.",
                             (float)sh * 0.34f, hint_size, CLR_DIM);
        } else {
            float row_h = body_size * 2.6f;
            float y0 = (float)sh * 0.22f;
            for (int i = 0; i < st->disk_count; i++) {
                struct playos_disk *d = &st->disks[i];
                float y = y0 + (float)i * row_h;
                bool sel = (i == st->cursor);

                if (sel)
                    DrawRectangle((int)content_x, (int)(y - body_size * 0.4f),
                                  (int)content_w, (int)(body_size * 2.0f),
                                  CLR_ACCENT);

                char line[512];
                double gb = (double)d->size_bytes / (1000.0 * 1000.0 * 1000.0);
                snprintf(line, sizeof(line), "%s", d->model);
                ui_text(line, content_x + body_size * 0.6f, y, body_size,
                        sel ? RAYWHITE : CLR_TEXT);

                char right[64];
                snprintf(right, sizeof(right), "%.0f GB", gb);
                ui_text(right,
                        content_x + content_w - ui_text_w(right, body_size)
                            - body_size * 0.6f,
                        y, body_size, sel ? RAYWHITE : CLR_DIM);
            }
        }
        ui_text("D-pad: choose   A: select   B: back", content_x, hint_y, hint_size, CLR_DIM);
        break;
    }

    case MODE_CONFIRM: {
        struct playos_disk *d = &st->disks[st->cursor];
        char line[512];
        snprintf(line, sizeof(line), "Erase %s and install PlayOS?", d->model);
        ui_text_centered(line, (float)sh * 0.26f, body_size, CLR_TEXT);
        ui_text_centered("Everything on this disk will be destroyed.",
                         (float)sh * 0.33f, hint_size, CLR_WARN);

        ui_text_centered("Hold A to install", (float)sh * 0.44f, body_size,
                         CLR_TEXT);
        ui_bar(content_x, (float)sh * 0.51f, content_w, hint_size * 1.6f,
               (float)st->confirm_progress / 180.0f, CLR_ACCENT);
        ui_text("B: cancel", content_x, hint_y, hint_size, CLR_DIM);
        break;
    }

    case MODE_INSTALLING: {
        struct playos_disk *d = &st->disks[st->cursor];
        char line[256];
        snprintf(line, sizeof(line), "%s  -  %s", d->path, d->model);
        ui_text(line, content_x, (float)sh * 0.20f, body_size, CLR_TEXT);

        float row_h = body_size * 1.9f;
        float y0 = (float)sh * 0.30f;
        for (int i = 0; i < 8; i++) {
            float y = y0 + (float)i * row_h;
            Color c;
            const char *mark;

            if (i < st->step_index) {
                c = CLR_DONE;
                mark = "[x]";
            } else if (i == st->step_index) {
                c = CLR_TEXT;
                mark = "[>]";
            } else {
                c = CLR_DIM;
                mark = "[ ]";
            }

            ui_text(mark, content_x, y, body_size, c);
            ui_text(STEP_NAMES[i], content_x + body_size * 3.2f, y, body_size,
                    c);
        }

        float bar_y = y0 + 8.0f * row_h + body_size;
        ui_bar(content_x, bar_y, content_w, hint_size * 1.6f,
               (float)st->step_index / 8.0f, CLR_ACCENT);

        char pct[64];
        snprintf(pct, sizeof(pct), "Step %d of 8", st->step_index + 1);
        ui_text(pct, content_x, bar_y + hint_size * 2.6f, hint_size, CLR_DIM);
        ui_text("Keep the device powered - this takes about a minute", content_x, hint_y, hint_size, CLR_DIM);
        break;
    }

    case MODE_SUCCESS: {
        ui_text_centered("PlayOS is installed", (float)sh * 0.34f,
                         title_size, CLR_DONE);
        ui_text_centered("Reboot to start using the internal disk.",
                         (float)sh * 0.44f, body_size, CLR_TEXT);
        ui_text("A: reboot now   B: power off", content_x, hint_y, hint_size, CLR_DIM);
        break;
    }

    case MODE_ERROR: {
        ui_text_centered("Install failed", (float)sh * 0.24f, title_size,
                         CLR_WARN);
        ui_text(st->step_name[0] ? st->step_name : "Unknown step",
                content_x, (float)sh * 0.34f, body_size, CLR_TEXT);
        ui_text_wrapped(st->err_buf, content_x, (float)sh * 0.40f, hint_size,
                        content_w, CLR_DIM, 4);
        ui_text("Log: /data/log/installer.log", content_x,
                (float)sh * 0.62f, hint_size, CLR_DIM);
        ui_text("A: try again   B: power off", content_x, hint_y, hint_size, CLR_DIM);
        break;
    }
    }

    EndDrawing();
}

/* ── entry point ───────────────────────────────────────────────────────── */

/* Headless automation hook — enabled only via the kernel command line token
 * playos.install.auto=1 (never present on a real installer USB). It runs the
 * full disk/format/efi state machine against the first fixed disk without a
 * GPU, gamepad or Raylib window, so the installer core can be exercised
 * deterministically under QEMU with a loopback target disk. */
static int
cmdline_has_token(const char *token)
{
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f)
        return 0;

    char buf[1024];
    int found = 0;
    if (fgets(buf, sizeof(buf), f)) {
        char *save = NULL;
        for (char *tok = strtok_r(buf, " \t\n", &save); tok;
             tok = strtok_r(NULL, " \t\n", &save)) {
            if (strcmp(tok, token) == 0) {
                found = 1;
                break;
            }
        }
    }
    fclose(f);
    return found;
}

int
main(void)
{
    if (cmdline_has_token("playos.install.auto=1")) {
        struct installer st;
        memset(&st, 0, sizeof(st));
        st.step_index = 0;
        st.step_error = -1;
        st.cursor = 0;
        st.evdev_fd = -1;
        st.payload_ok = 0;

        if (playos_disk_enumerate(&st.disks, &st.disk_count) != 0) {
            fprintf(stderr, "AUTO: disk enumeration failed\n");
            return EXIT_FAILURE;
        }
        if (find_and_mount_payload(st.payload_mount, sizeof(st.payload_mount)) == 0)
            st.payload_ok = 1;

        if (st.disk_count <= 0) {
            fprintf(stderr, "AUTO: no install target disk found\n");
            return EXIT_FAILURE;
        }
        if (!st.payload_ok) {
            fprintf(stderr, "AUTO: installer payload not found\n");
            return EXIT_FAILURE;
        }

        /* Never install onto the payload medium itself: resolve the disk
         * behind /dev/disk/by-label/playos-a and skip it when picking the
         * first fixed target (S13.7 headless QEMU safety). */
        char payload_disk[64] = {0};
        char resolved[256] = {0};
        ssize_t rl = readlink("/dev/disk/by-label/playos-a", resolved,
                              sizeof(resolved) - 1);
        if (rl > 0) {
            resolved[rl] = '\0';
            const char *base = strrchr(resolved, '/');
            base = base ? base + 1 : resolved;
            size_t len = strlen(base);
            while (len > 0 && isdigit((unsigned char)base[len - 1]))
                len--;
            if (len > 0)
                snprintf(payload_disk, sizeof(payload_disk), "/dev/%.*s",
                         (int)len, base);
        }

        int target_idx = -1;
        for (int i = 0; i < st.disk_count; i++) {
            if (st.disks[i].removable)
                continue;
            if (payload_disk[0] &&
                strcmp(st.disks[i].path, payload_disk) == 0)
                continue;
            target_idx = i;
            break;
        }
        if (target_idx < 0) {
            fprintf(stderr, "AUTO: no install target disk found "
                    "(all disks are removable or are the payload medium)\n");
            return EXIT_FAILURE;
        }

        st.mode = MODE_INSTALLING;
        st.cursor = target_idx;
        fprintf(stdout, "AUTO: installing to %s (%s)\n",
                st.disks[st.cursor].path, st.disks[st.cursor].model);

        while (st.mode == MODE_INSTALLING) {
            fprintf(stdout, "AUTO: step %d/8 %s\n", st.step_index,
                    STEP_NAMES[st.step_index]);
            if (run_install_step(&st) != 0) {
                fprintf(stderr, "AUTO: FAILED step %d (%s): %s\n",
                        st.step_index, st.step_name, st.err_buf);
                return EXIT_FAILURE;
            }
        }

        fprintf(stdout, "AUTO: install %s\n",
                st.mode == MODE_SUCCESS ? "SUCCESS" : "FAILED");
        return (st.mode == MODE_SUCCESS) ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    if (platform_playos_preconnect() != 0) {
        fprintf(stderr, "playos-installer: platform_playos_preconnect failed\n");
        return EXIT_FAILURE;
    }

    struct playos_manager_v1 *mgr = platform_get_playos_manager();
    if (!mgr) {
        fprintf(stderr, "playos-installer: no playos manager\n");
        return EXIT_FAILURE;
    }

    playos_manager_v1_register_shell(mgr);
    platform_playos_flush();

    InitWindow(1920, 1080, "PlayOS Installer");
    if (!IsWindowReady()) {
        fprintf(stderr, "playos-installer: InitWindow failed\n");
        return EXIT_FAILURE;
    }
    load_ui_font();
    SetTargetFPS(60);

    struct installer st;
    memset(&st, 0, sizeof(st));
    st.mode = MODE_DISCOVERY;
    st.disks = NULL;
    st.disk_count = 0;
    st.cursor = 0;
    st.confirm_progress = 0;
    st.step_index = 0;
    st.step_error = -1;
    st.splash_start = GetTime();
    st.evdev_fd = find_gamepad();
    st.payload_ok = 0;

    if (playos_disk_enumerate(&st.disks, &st.disk_count) != 0) {
        snprintf(st.err_buf, sizeof(st.err_buf), "disk enumeration failed");
        st.step_error = -1;
        snprintf(st.step_name, sizeof(st.step_name), "Discovery");
        st.mode = MODE_ERROR;
    }

    if (find_and_mount_payload(st.payload_mount,
                               sizeof(st.payload_mount)) == 0)
        st.payload_ok = 1;

    installer_logf("installer started: disks=%d payload=%s payload_ok=%d",
                   st.disk_count,
                   st.payload_ok ? st.payload_mount : "(none)",
                   st.payload_ok);

    /* S14-T10: when the shell's installer front-end already showed the disk
     * list and took the destructive confirmation, init passes the chosen disk
     * in PLAYOS_INSTALL_TARGET and we start installing straight away — no
     * second picker and no second confirmation. An unknown path (or none)
     * falls back to the interactive flow, and MODE_INSTALLING still verifies
     * the payload itself before anything touches the disk. */
    const char *preselected = getenv("PLAYOS_INSTALL_TARGET");
    if (preselected && preselected[0]) {
        int idx = -1;
        for (int i = 0; i < st.disk_count; i++) {
            if (strcmp(st.disks[i].path, preselected) == 0) {
                idx = i;
                break;
            }
        }
        if (idx >= 0) {
            st.cursor = idx;
            st.confirm_progress = 0;
            st.step_index = 0;
            st.step_error = -1;
            st.err_buf[0] = '\0';
            installer_logf("preselected target %s (%s) — skipping picker and "
                           "confirmation", st.disks[idx].path,
                           st.disks[idx].model);
            st.mode = MODE_INSTALLING;
        } else {
            installer_logf("PLAYOS_INSTALL_TARGET=%s matches no enumerated "
                           "disk — falling back to the picker", preselected);
        }
    }

    while (!WindowShouldClose()) {
        poll_input(st.evdev_fd, &st.input);

        switch (st.mode) {
        case MODE_DISCOVERY:
            if (st.disk_count > 0) {
                if (st.input.up_press)
                    st.cursor = (st.cursor - 1 + st.disk_count) % st.disk_count;
                if (st.input.down_press)
                    st.cursor = (st.cursor + 1) % st.disk_count;
                if (st.input.a_press) {
                    st.confirm_progress = 0;
                    st.mode = MODE_CONFIRM;
                    installer_logf("installer mode -> CONFIRM (target=%s)",
                                   st.disks[st.cursor].device);
                }
            }
            if (st.input.b_press)
                reboot(RB_POWER_OFF);
            break;

        case MODE_CONFIRM:
            if (st.input.b_press) {
                installer_logf("installer mode -> DISCOVERY (cancel)");
                st.mode = MODE_DISCOVERY;
            } else if (st.input.a_down) {
                st.confirm_progress++;
                if (st.confirm_progress >= 180) {
                    st.confirm_progress = 0;
                    st.step_index = 0;
                    st.step_error = -1;
                    st.err_buf[0] = '\0';
                    st.mode = MODE_INSTALLING;
                    installer_logf("installer mode -> INSTALLING (target=%s)",
                                   st.disks[st.cursor].device);
                }
            } else {
                st.confirm_progress = 0;
            }
            break;

        case MODE_INSTALLING:
            if (!st.payload_ok) {
                snprintf(st.err_buf, sizeof(st.err_buf),
                         "installer payload not found on the boot medium");
                snprintf(st.step_name, sizeof(st.step_name), "Payload");
                st.step_error = -1;
                st.mode = MODE_ERROR;
                installer_logf("installer mode -> ERROR (payload missing)");
            } else {
                (void)run_install_step(&st);
            }
            break;

        case MODE_SUCCESS:
            if (st.input.a_press) {
                sync();
                reboot(RB_AUTOBOOT);
            } else if (st.input.b_press) {
                sync();
                reboot(RB_POWER_OFF);
            }
            break;

        case MODE_ERROR:
            if (st.input.a_press) {
                installer_logf("installer mode -> DISCOVERY (retry)");
                st.mode = MODE_DISCOVERY;
                st.err_buf[0] = '\0';
                st.step_error = -1;
                st.step_index = 0;
            } else if (st.input.b_press) {
                sync();
                reboot(RB_POWER_OFF);
            }
            break;
        }

        draw_ui(&st);
    }

    if (st.evdev_fd >= 0)
        close(st.evdev_fd);
    playos_disk_free(st.disks, st.disk_count);
    CloseWindow();
    return EXIT_SUCCESS;
}
