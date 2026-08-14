/**
 * main.c — PlayOS trusted in-game overlay
 *
 * A Raylib client, pre-spawned by playos-init and hidden. The compositor
 * maps/unmaps it in response to the reserved SYSTEM button; this process
 * never manages its own visibility, it only listens for about_to_show /
 * about_to_hide and renders a status card while visible.
 *
 * Control flows over the Wayland protocol (playos_overlay_v1): the overlay
 * requests dismissal (Resume) and asks playos-init to terminate the active
 * game (Quit) over the trusted /run/playos/control.sock socket via
 * libplayos-trusted. It is a trusted system component and must NOT be
 * confused with a game client.
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <time.h>

#include <wayland-client.h>
#include <sys/ioctl.h>

/* raylib.h must be included before <linux/input.h>: the kernel headers
 * #define KEY_* macros that collide with raylib's KeyboardKey enum. */
#include "raylib.h"

#include <linux/input.h>
#include <linux/input-event-codes.h>

#include "playos-v1-client-protocol.h"
#include "playos-runtime/trusted_control.h"

/* ── Raylib PlayOS backend accessors ─────────────────────────────────────
 * Declared here because the vendored raylib builds the PlayOS backend
 * (rcore_playos.c) without exporting these through a public header. */
extern struct playos_manager_v1 *platform_get_playos_manager(void);
extern struct playos_overlay_v1 *platform_get_playos_overlay(void);
extern struct wl_surface *platform_get_wl_surface(void);
extern void platform_playos_flush(void);
extern int  platform_playos_preconnect(void);

/* ── Overlay state ─────────────────────────────────────────────────────── */

struct overlay_state {
    struct playos_overlay_v1 *overlay;
    bool visible;
    int output_width;
    int output_height;
    uint32_t refresh_mhz;
    uint32_t scale_100;
    char status_buf[512];
    bool status_valid;
    struct timespec shown_at;
    bool shown_at_valid;
};

/* ── playos_overlay_v1 listener ───────────────────────────────────────── */

static void
overlay_handle_about_to_show(void *data, struct playos_overlay_v1 *overlay)
{
    (void)overlay;
    struct overlay_state *st = data;

    st->visible = true;
    clock_gettime(CLOCK_MONOTONIC, &st->shown_at);
    st->shown_at_valid = true;

    /* Refresh the active-game status every time the overlay is raised. */
    memset(st->status_buf, 0, sizeof(st->status_buf));
    st->status_valid =
        (playos_trusted_query_status(-1, st->status_buf,
                                     sizeof(st->status_buf)) == 0);
}

static void
overlay_handle_about_to_hide(void *data, struct playos_overlay_v1 *overlay)
{
    (void)overlay;
    struct overlay_state *st = data;

    st->visible = false;
    st->shown_at_valid = false;
}

static void
overlay_handle_output_info(void *data, struct playos_overlay_v1 *overlay,
                           int32_t width, int32_t height,
                           uint32_t refresh_mhz, uint32_t scale_100)
{
    (void)overlay;
    struct overlay_state *st = data;

    st->output_width = width;
    st->output_height = height;
    st->refresh_mhz = refresh_mhz;
    st->scale_100 = scale_100;
}

static const struct playos_overlay_v1_listener overlay_listener = {
    .about_to_show = overlay_handle_about_to_show,
    .about_to_hide = overlay_handle_about_to_hide,
    .output_info  = overlay_handle_output_info,
};

/* ── Direct evdev controller input ───────────────────────────────────────
 * The overlay is trusted, so it reads the controller directly for the two
 * reserved actions. It only needs A (Resume) and B (Quit game). */

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

static void
poll_input(int fd, int *a_pressed, int *b_pressed)
{
    *a_pressed = 0;
    *b_pressed = 0;

    if (fd < 0)
        return;

    struct input_event ev;
    while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
        if (ev.type != EV_KEY || ev.value != 1) /* press edge only */
            continue;
        if (ev.code == BTN_SOUTH)
            *a_pressed = 1;
        else if (ev.code == BTN_EAST)
            *b_pressed = 1;
    }
}

/* ── Minimal JSON field extraction ────────────────────────────────────── */

static void
extract_game_id(const char *json, char *out, size_t outsz)
{
    out[0] = '\0';
    if (!json)
        return;

    const char *key = strstr(json, "\"game_id\"");
    if (!key)
        return;
    const char *colon = strchr(key, ':');
    if (!colon)
        return;

    colon++;
    while (*colon == ' ' || *colon == '\t')
        colon++;

    if (*colon != '"')
        return;
    colon++;

    size_t i = 0;
    while (*colon && *colon != '"' && (i + 1) < outsz)
        out[i++] = *colon++;
    out[i] = '\0';
}

/* ── Entry point ───────────────────────────────────────────────────────── */

int
main(int argc, char *argv[])
{
    (void)argc;
    (void)argv;

    /* Connect to Wayland and bind the PlayOS globals BEFORE creating any
     * surface. The compositor classifies a client's role when its
     * xdg_toplevel is created, so registration must come first — otherwise
     * this window would be misclassified as a GAME surface. */
    if (platform_playos_preconnect() != 0) {
        fprintf(stderr, "overlay: wayland preconnect failed\n");
        return EXIT_FAILURE;
    }

    struct playos_manager_v1 *mgr = platform_get_playos_manager();
    if (!mgr) {
        fprintf(stderr, "overlay: playos_manager_v1 unavailable\n");
        return EXIT_FAILURE;
    }

    playos_manager_v1_register_overlay(mgr);
    platform_playos_flush();

    /* Now create the fullscreen overlay surface. */
    InitWindow(1280, 720, "PlayOS Overlay");
    if (!IsWindowReady()) {
        fprintf(stderr, "overlay: InitWindow failed\n");
        return EXIT_FAILURE;
    }

    struct overlay_state st;
    memset(&st, 0, sizeof(st));
    st.output_width = 1280;
    st.output_height = 720;
    st.refresh_mhz = 60000;
    st.scale_100 = 100;

    struct playos_overlay_v1 *overlay = platform_get_playos_overlay();
    st.overlay = overlay;
    if (overlay) {
        playos_overlay_v1_add_listener(overlay, &overlay_listener, &st);

        struct wl_surface *surface = platform_get_wl_surface();
        if (surface)
            playos_overlay_v1_set_surface(overlay, surface);

        platform_playos_flush();
    }

    int evdev_fd = find_gamepad();
    if (evdev_fd < 0)
        fprintf(stderr, "overlay: no gamepad found — input disabled\n");

    bool first_frame = true;

    while (!WindowShouldClose()) {
        int a_pressed = 0;
        int b_pressed = 0;
        poll_input(evdev_fd, &a_pressed, &b_pressed);

        if (a_pressed && overlay) {
            /* Resume: ask the compositor to hide us. */
            playos_overlay_v1_request_dismiss(overlay);
            platform_playos_flush();
        }

        if (b_pressed) {
            /* Quit active game via playos-init's trusted control socket. */
            if (playos_trusted_terminate_game(-1) != 0)
                fprintf(stderr, "overlay: TerminateGame failed\n");
            platform_playos_flush();
        }

        BeginDrawing();
        ClearBackground((Color){ 12, 12, 16, 255 });

        if (st.visible) {
            int w = GetScreenWidth();
            int h = GetScreenHeight();
            int margin = w / 40;

            DrawRectangle(0, 0, w, h, (Color){ 0, 0, 0, 150 });

            DrawText("PlayOS", margin, margin, 48, RAYWHITE);

            char line[512];
            if (st.status_valid) {
                char game_id[128];
                extract_game_id(st.status_buf, game_id, sizeof(game_id));
                snprintf(line, sizeof(line), "Game: %s",
                         game_id[0] ? game_id : "(no active game)");
            } else {
                snprintf(line, sizeof(line), "Game: (status unavailable)");
            }
            DrawText(line, margin, margin + 64, 20, LIGHTGRAY);

            if (st.shown_at_valid) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                long elapsed = now.tv_sec - st.shown_at.tv_sec;
                snprintf(line, sizeof(line), "Elapsed: %lds", elapsed);
                DrawText(line, margin, margin + 92, 20, LIGHTGRAY);
            }

            snprintf(line, sizeof(line), "Battery: 85%%   Thermal: Normal");
            DrawText(line, margin, margin + 120, 20, LIGHTGRAY);

            DrawText("A: Resume    B: Quit game",
                     margin, h - margin - 30, 20, GRAY);
        }

        EndDrawing();

        /* Tell the compositor we've rendered our first frame. */
        if (first_frame && overlay) {
            playos_overlay_v1_surface_ready(overlay);
            platform_playos_flush();
            first_frame = false;
        }
    }

    CloseWindow();
    if (evdev_fd >= 0)
        close(evdev_fd);

    return EXIT_SUCCESS;
}
