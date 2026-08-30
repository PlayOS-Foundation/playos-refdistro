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
    case 0: rc = playos_format_partition_disk(dev, err, errlen); break;
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
            rc = playos_format_seed_ssh_keys(dev, 5, src, err, errlen);
            installer_logf("installer step 5/8 Format data: ssh key source %s, seed rc=%d",
                           key_present ? "present" : "absent", rc);
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

static void
draw_centered(const char *text, int y, int size, Color color)
{
    int w = MeasureText(text, size);
    DrawText(text, (1920 - w) / 2, y, size, color);
}

static void
draw_ui(struct installer *st)
{
    BeginDrawing();
    ClearBackground((Color){12, 12, 18, 255});

    DrawText("PlayOS Installer", 48, 32, 44, RAYWHITE);
    draw_centered(mode_title(st->mode), 96, 30, (Color){180, 180, 210, 255});

    switch (st->mode) {
    case MODE_DISCOVERY: {
        if (st->disk_count == 0) {
            draw_centered("No fixed internal disk found.", 240, 26, RAYWHITE);
            draw_centered("Attach an internal NVMe/SATA disk and restart.",
                          280, 22, (Color){150, 150, 170, 255});
        } else {
            for (int i = 0; i < st->disk_count; i++) {
                struct playos_disk *d = &st->disks[i];
                int y = 200 + i * 64;
                bool sel = (i == st->cursor);
                if (sel)
                    DrawRectangle(60, y - 8, 1800, 56,
                                  (Color){60, 40, 120, 255});

                char line[512];
                double gb = (double)d->size_bytes / (1024.0 * 1024.0 * 1024.0);
                snprintf(line, sizeof(line), "%s  -  %.1f GiB  -  %s  (%d partitions)",
                         d->path, gb, d->model, d->partitions);
                DrawText(line, 84, y, 28,
                         sel ? RAYWHITE : (Color){200, 200, 210, 255});
            }
            draw_centered("A: select    D-pad: move    B: power off",
                          980, 22, (Color){140, 140, 160, 255});
        }
        break;
    }

    case MODE_CONFIRM: {
        struct playos_disk *d = &st->disks[st->cursor];
        char line[512];
        snprintf(line, sizeof(line), "Target: %s (%s)",
                 d->path, d->model);
        draw_centered(line, 260, 30, RAYWHITE);
        draw_centered("This will DESTROY ALL DATA on the selected disk.",
                      330, 26, (Color){255, 120, 120, 255});
        draw_centered("Hold A for 3 seconds to install.", 430, 24, RAYWHITE);

        int bar_w = 1200;
        int bar_x = (1920 - bar_w) / 2;
        int bar_h = 36;
        int bar_y = 500;
        DrawRectangle(bar_x, bar_y, bar_w, bar_h, (Color){40, 40, 52, 255});
        DrawRectangle(bar_x, bar_y,
                      (bar_w * st->confirm_progress) / 180, bar_h,
                      (Color){120, 70, 200, 255});

        draw_centered("B: cancel", 580, 22, (Color){150, 150, 170, 255});
        break;
    }

    case MODE_INSTALLING: {
        draw_centered(st->disks[st->cursor].path, 200, 26, RAYWHITE);
        for (int i = 0; i < 8; i++) {
            int y = 260 + i * 56;
            Color c;
            if (i < st->step_index)
                c = (Color){80, 200, 120, 255};
            else if (i == st->step_index)
                c = RAYWHITE;
            else
                c = (Color){110, 110, 125, 255};

            char line[96];
            if (i < st->step_index)
                snprintf(line, sizeof(line), "[done]  %s", STEP_NAMES[i]);
            else if (i == st->step_index)
                snprintf(line, sizeof(line), "[....]  %s", STEP_NAMES[i]);
            else
                snprintf(line, sizeof(line), "[    ]  %s", STEP_NAMES[i]);
            DrawText(line, 300, y, 28, c);
        }
        break;
    }

    case MODE_SUCCESS: {
        draw_centered("PlayOS has been installed to the internal disk.",
                      300, 30, (Color){120, 220, 160, 255});
        draw_centered("A: reboot    B: power off", 420, 26, RAYWHITE);
        break;
    }

    case MODE_ERROR: {
        draw_centered(st->step_name, 260, 28, (Color){255, 130, 130, 255});
        DrawText(st->err_buf, 120, 320, 20, (Color){220, 200, 200, 255});
        draw_centered("A: back    B: power off", 980, 22, RAYWHITE);
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
