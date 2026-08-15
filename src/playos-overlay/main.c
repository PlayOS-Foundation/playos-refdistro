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
#include "playos/playos.h"

/* ── Raylib PlayOS backend accessors ─────────────────────────────────────
 * Declared here because the vendored raylib builds the PlayOS backend
 * (rcore_playos.c) without exporting these through a public header. */
extern struct playos_manager_v1 *platform_get_playos_manager(void);
extern struct playos_overlay_v1 *platform_get_playos_overlay(void);
extern struct wl_surface *platform_get_wl_surface(void);
extern void platform_playos_flush(void);
extern int  platform_playos_preconnect(void);

/* ── Overlay interaction modes (Sprint 9) ──────────────────────────────── */

enum overlay_mode {
    OVERLAY_MODE_NORMAL,   /* Resume / Quit game / Volume */
    OVERLAY_MODE_PROFILE,  /* D-pad L/R select performance profile, A applies */
    OVERLAY_MODE_POWER,    /* Sleep / Restart / Shutdown menu */
};

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

    /* Sprint 9: live power status + profile/power selection. */
    enum overlay_mode mode;
    int               profile_index;    /* 0=balanced,1=power_save,2=performance */
    int               power_cursor;     /* 0=Sleep,1=Restart,2=Shutdown */
    PlayOSPowerInfo   power_info;
    bool              power_info_valid;
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
poll_input(int fd, int *a_pressed, int *b_pressed,
           int *vol_up_pressed, int *vol_down_pressed,
           int *dpad_left_pressed, int *dpad_right_pressed,
           int *select_pressed)
{
    *a_pressed = 0;
    *b_pressed = 0;
    *vol_up_pressed = 0;
    *vol_down_pressed = 0;
    *dpad_left_pressed = 0;
    *dpad_right_pressed = 0;
    *select_pressed = 0;

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
        else if (ev.code == BTN_DPAD_UP)
            *vol_up_pressed = 1;
        else if (ev.code == BTN_DPAD_DOWN)
            *vol_down_pressed = 1;
        else if (ev.code == BTN_DPAD_LEFT)
            *dpad_left_pressed = 1;
        else if (ev.code == BTN_DPAD_RIGHT)
            *dpad_right_pressed = 1;
        else if (ev.code == BTN_SELECT)
            *select_pressed = 1;
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

/* ── Power / profile presentation helpers (Sprint 9) ───────────────────── */

static const char *
overlay_profile_name(int profile)
{
    switch (profile) {
    case PLAYOS_PERF_POWER_SAVE:  return "Power Save";
    case PLAYOS_PERF_PERFORMANCE: return "Performance";
    case PLAYOS_PERF_BALANCED:
    default:                      return "Balanced";
    }
}

static const char *
overlay_thermal_name(int state)
{
    switch (state) {
    case PLAYOS_THERMAL_WARM:     return "Warm";
    case PLAYOS_THERMAL_HOT:      return "Hot";
    case PLAYOS_THERMAL_CRITICAL: return "Critical";
    case PLAYOS_THERMAL_NORMAL:
    default:                      return "Normal";
    }
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
    bool audio_defaults_applied = false;

    while (!WindowShouldClose()) {
        int a_pressed = 0;
        int b_pressed = 0;
        int vol_up_pressed = 0;
        int vol_down_pressed = 0;
        int dpad_left_pressed = 0;
        int dpad_right_pressed = 0;
        int select_pressed = 0;
        poll_input(evdev_fd, &a_pressed, &b_pressed,
                   &vol_up_pressed, &vol_down_pressed,
                   &dpad_left_pressed, &dpad_right_pressed,
                   &select_pressed);

        /* Read the system master volume once per frame for the card and
         * use it as the baseline for d-pad volume steps. */
        PlayOSAudioInfo audio_info;
        (void)playos_audio_get_info(&audio_info);

        /* Live power/thermal status (Sprint 9). playos_power_get_info()
         * caches sysfs reads for 1s internally, so per-frame calls are cheap. */
        if (st.visible) {
            if (playos_power_get_info(&st.power_info) == 0)
                st.power_info_valid = true;
        }

        /* D-pad L/R: select a performance profile (A applies it). */
        if ((dpad_left_pressed || dpad_right_pressed) &&
            st.mode != OVERLAY_MODE_POWER) {
            if (st.mode != OVERLAY_MODE_PROFILE) {
                st.mode = OVERLAY_MODE_PROFILE;
                st.profile_index = st.power_info_valid
                                   ? (int)st.power_info.active_profile
                                   : PLAYOS_PERF_BALANCED;
            }
            if (dpad_left_pressed)
                st.profile_index--;
            else
                st.profile_index++;
            if (st.profile_index < 0)
                st.profile_index = 2;
            if (st.profile_index > 2)
                st.profile_index = 0;
        }

        /* SELECT toggles the power menu (Sleep / Restart / Shutdown). */
        if (select_pressed) {
            if (st.mode == OVERLAY_MODE_POWER)
                st.mode = OVERLAY_MODE_NORMAL;
            else if (st.mode == OVERLAY_MODE_NORMAL)
                st.mode = OVERLAY_MODE_POWER;
        }

        if (st.mode == OVERLAY_MODE_POWER) {
            if (vol_up_pressed) {
                if (st.power_cursor > 0)
                    st.power_cursor--;
            }
            if (vol_down_pressed) {
                if (st.power_cursor < 2)
                    st.power_cursor++;
            }
            if (a_pressed) {
                if (st.power_cursor == 0) {
                    if (playos_trusted_suspend(-1) != 0)
                        fprintf(stderr, "overlay: Suspend failed\n");
                } else if (st.power_cursor == 1) {
                    if (playos_trusted_reboot(-1) != 0)
                        fprintf(stderr, "overlay: Reboot failed\n");
                } else {
                    if (playos_trusted_shutdown(-1) != 0)
                        fprintf(stderr, "overlay: Shutdown failed\n");
                }
                platform_playos_flush();
                st.mode = OVERLAY_MODE_NORMAL;
            }
            if (b_pressed)
                st.mode = OVERLAY_MODE_NORMAL;
        } else if (st.mode == OVERLAY_MODE_PROFILE) {
            if (a_pressed) {
                if (playos_trusted_set_perf_profile(-1, st.profile_index) != 0)
                    fprintf(stderr, "overlay: SetPerfProfile failed\n");
                platform_playos_flush();
                st.mode = OVERLAY_MODE_NORMAL;
            }
            if (b_pressed)
                st.mode = OVERLAY_MODE_NORMAL;
        } else {
            /* NORMAL: resume, quit game, and volume control. */
            if (vol_up_pressed || vol_down_pressed) {
                float vol = audio_info.master_volume;
                if (vol_up_pressed)
                    vol += 0.05f;
                else
                    vol -= 0.05f;
                if (vol < 0.0f)
                    vol = 0.0f;
                if (vol > 1.0f)
                    vol = 1.0f;
                (void)playos_audio_set_master_volume(vol);
            }

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

            /* Live power + thermal status (Sprint 9). */
            char power_line[256];
            if (st.power_info_valid) {
                char batt[64];
                if (st.power_info.battery_percent >= 0) {
                    const char *ac = "";
                    if (st.power_info.power_state == PLAYOS_POWER_STATE_CHARGING)
                        ac = " (Charging)";
                    else if (st.power_info.power_state == PLAYOS_POWER_STATE_CHARGED)
                        ac = " (AC)";
                    snprintf(batt, sizeof(batt), "Battery: %d%%%s",
                             st.power_info.battery_percent, ac);
                } else {
                    snprintf(batt, sizeof(batt), "Battery: --");
                }
                snprintf(power_line, sizeof(power_line), "%s   Thermal: %s",
                         batt, overlay_thermal_name(st.power_info.thermal_state));
            } else {
                snprintf(power_line, sizeof(power_line),
                         "Battery: --   Thermal: --");
            }
            DrawText(power_line, margin, margin + 120, 20, LIGHTGRAY);

            if (st.power_info_valid &&
                (st.power_info.cpu_temp_c >= 0 || st.power_info.gpu_temp_c >= 0)) {
                char temp_line[128];
                if (st.power_info.cpu_temp_c >= 0 && st.power_info.gpu_temp_c >= 0)
                    snprintf(temp_line, sizeof(temp_line), "CPU: %dC   GPU: %dC",
                             st.power_info.cpu_temp_c, st.power_info.gpu_temp_c);
                else if (st.power_info.cpu_temp_c >= 0)
                    snprintf(temp_line, sizeof(temp_line), "CPU: %dC",
                             st.power_info.cpu_temp_c);
                else
                    snprintf(temp_line, sizeof(temp_line), "GPU: %dC",
                             st.power_info.gpu_temp_c);
                DrawText(temp_line, margin, margin + 148, 20, LIGHTGRAY);
            }

            snprintf(line, sizeof(line), "Volume: %.0f%%%s",
                     audio_info.master_volume * 100.0f,
                     audio_info.muted ? "  (muted)" : "");
            DrawText(line, margin, margin + 176, 20,
                     audio_info.muted ? ORANGE : LIGHTGRAY);

            /* Performance profile selector. */
            if (st.mode == OVERLAY_MODE_PROFILE) {
                DrawText("Profile:", margin, margin + 204, 20, RAYWHITE);
                static const char *profiles[3] = {
                    "Balanced", "Power Save", "Performance"
                };
                for (int i = 0; i < 3; i++) {
                    char item[64];
                    snprintf(item, sizeof(item), "%s%s",
                             (i == st.profile_index) ? "> " : "  ",
                             profiles[i]);
                    DrawText(item, margin, margin + 232 + i * 28, 20,
                             (i == st.profile_index) ? YELLOW : LIGHTGRAY);
                }
            }

            /* Power menu (Sleep / Restart / Shutdown). */
            if (st.mode == OVERLAY_MODE_POWER) {
                DrawText("Power:", margin, margin + 204, 20, RAYWHITE);
                static const char *powers[3] = {
                    "Sleep", "Restart", "Shutdown"
                };
                for (int i = 0; i < 3; i++) {
                    char item[64];
                    snprintf(item, sizeof(item), "%s%s",
                             (i == st.power_cursor) ? "> " : "  ",
                             powers[i]);
                    DrawText(item, margin, margin + 232 + i * 28, 20,
                             (i == st.power_cursor) ? YELLOW : LIGHTGRAY);
                }
            }

            const char *hint;
            if (st.mode == OVERLAY_MODE_PROFILE)
                hint = "A: Apply    B: Back    Left/Right: Change";
            else if (st.mode == OVERLAY_MODE_POWER)
                hint = "A: Confirm    B: Back    Up/Down: Select";
            else
                hint = "A: Resume    B: Quit game    D-pad: Volume    Select: Power";
            DrawText(hint, margin, h - margin - 30, 20, GRAY);
        }

        EndDrawing();

        /* One-time bootstrap: the Realtek codec powers up with its speaker
         * volume at minimum and the speaker pin muted. The mixer card may not
         * be registered yet on the first frame (CS35L41 calibration takes a
         * few seconds), so retry until both operations actually succeed
         * instead of relying on first-frame timing. */
        if (!audio_defaults_applied) {
            if (playos_audio_set_master_volume(0.7f) == 0 &&
                playos_audio_set_muted(0) == 0) {
                audio_defaults_applied = true;
            }
        }

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
