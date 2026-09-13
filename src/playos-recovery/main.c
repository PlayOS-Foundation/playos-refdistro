/*
 * playos-recovery — GL-free recovery UI (Sprint 14, F3)
 *
 * The recovery menu normally lives in playos-shell, which is a GL client: if the
 * GPU/GL stack is what broke, EGL cannot be initialised against a software
 * (pixman) compositor and the shell crash-loops, leaving an empty compositor on
 * screen. This program is the answer for that case. It needs nothing but core
 * Wayland:
 *
 *   - a `wl_shm` buffer it paints itself, so it works with any renderer the
 *     compositor chooses (GLES2, pixman, SimplEDRM-over-software), and
 *   - evdev for input, so it does not depend on the shell, the seat or a GPU.
 *
 * Text is rasterised with stb_truetype (public domain) from the same Silkscreen
 * TTF the shell and installer use. The actions are the same as the shell's
 * recovery screen and go through the trusted IPC to playos-init, which owns the
 * A/B slot metadata and the shutdown path.
 *
 * SPDX-License-Identifier: MIT
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include "playos-runtime/trusted_control.h"

/* ── palette (matches the shell) ─────────────────────────────────────────── */
#define CLR_BG_R 20
#define CLR_BG_G 41
#define CLR_BG_B 76
#define CLR_HL_R 214
#define CLR_HL_G 107
#define CLR_HL_B 0

#define MAX_LOGS   32
#define LOG_LINES  4096
#define LOG_VIEW_LINES 22

enum { MODE_MENU, MODE_LOGLIST, MODE_LOGVIEW, MODE_CONFIRM };

struct glyph_cache {
    unsigned char *bitmap;
    int w, h, xoff, yoff;
    int advance;
};

struct recovery {
    /* wayland */
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xsurface;
    struct xdg_toplevel *toplevel;
    struct wl_callback *frame_cb;
    struct wl_buffer *buffer;
    bool buffer_busy;
    void *pixels;
    size_t pixels_size;
    int width, height, stride;
    bool configured;
    bool dirty;
    bool running;

    /* font */
    unsigned char *ttf;
    stbtt_fontinfo font;
    float px;           /* glyph height in pixels */
    float scale;

    /* ui */
    int mode;
    int cursor;
    int log_cursor;
    int log_scroll;
    char confirm_text[64];
    char toast[128];

    /* logs */
    char log_name[MAX_LOGS][64];
    int  log_count;
    char *log_lines[LOG_LINES];
    char *log_buf;
    int  log_line_count;

    /* input */
    struct pollfd fds[16];
    int nfds;
};

/* ── shm helper ──────────────────────────────────────────────────────────── */

static int
create_shm_file(size_t size)
{
    int fd = memfd_create("playos-recovery", MFD_CLOEXEC);
    if (fd < 0)
        return -1;
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void
buffer_release(void *data, struct wl_buffer *buffer)
{
    struct recovery *r = data;
    wl_buffer_destroy(buffer);
    r->buffer = NULL;
    r->buffer_busy = false;
}

static const struct wl_buffer_listener buffer_listener = {
    .release = buffer_release,
};

/* ── painting ────────────────────────────────────────────────────────────── */

static void
put_px(struct recovery *r, int x, int y, int cr, int cg, int cb)
{
    if (x < 0 || y < 0 || x >= r->width || y >= r->height)
        return;
    unsigned char *p = (unsigned char *)r->pixels +
                       (size_t)y * r->stride + (size_t)x * 4;
    /* wl_shm ARGB8888/XRGB8888: memory order B,G,R,X on little-endian */
    p[0] = (unsigned char)cb;
    p[1] = (unsigned char)cg;
    p[2] = (unsigned char)cr;
    p[3] = 255;
}

static void
fill_rect(struct recovery *r, int x, int y, int w, int h,
          int cr, int cg, int cb)
{
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++)
            put_px(r, x + i, y + j, cr, cg, cb);
}

static void
text_width(struct recovery *r, const char *s, int px, float *out_w, float *out_h)
{
    float x = 0.0f;
    float scale = stbtt_ScaleForPixelHeight(&r->font, (float)px);
    int ascent = 0, descent = 0, linegap = 0;
    stbtt_GetFontVMetrics(&r->font, &ascent, &descent, &linegap);

    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int adv = 0, lsb = 0;
        stbtt_GetCodepointHMetrics(&r->font, *p, &adv, &lsb);
        x += (float)adv * scale;
    }
    if (out_w)
        *out_w = x;
    if (out_h)
        *out_h = (float)(ascent - descent) * scale;
}

/* `y_top` is the top of the text line box; stb_truetype positions glyph bitmaps
 * relative to the baseline, so convert once here - otherwise every string sits
 * off-centre inside its highlight box. */
static void
draw_text(struct recovery *r, const char *s, int x, int y_top, int px,
          int cr, int cg, int cb)
{
    float scale = stbtt_ScaleForPixelHeight(&r->font, (float)px);
    float pen = (float)x;

    int ascent = 0, descent = 0, linegap = 0;
    stbtt_GetFontVMetrics(&r->font, &ascent, &descent, &linegap);
    int y = y_top + (int)((float)ascent * scale + 0.5f);

    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int adv = 0, lsb = 0;
        stbtt_GetCodepointHMetrics(&r->font, *p, &adv, &lsb);

        int w = 0, h = 0, xoff = 0, yoff = 0;
        unsigned char *bm = stbtt_GetCodepointBitmap(&r->font, scale, scale,
                                                     *p, &w, &h, &xoff, &yoff);
        if (bm) {
            for (int j = 0; j < h; j++) {
                for (int i = 0; i < w; i++) {
                    int a = bm[j * w + i];
                    if (!a)
                        continue;
                    int sx = (int)pen + xoff + i;
                    int sy = y + yoff + j;
                    if (x < 0 || sy < 0 || sx >= r->width || sy >= r->height)
                        continue;
                    unsigned char *dst = (unsigned char *)r->pixels +
                                         (size_t)sy * r->stride + (size_t)sx * 4;
                    /* blend the glyph over the existing pixel */
                    dst[0] = (unsigned char)((cb * a + dst[0] * (255 - a)) / 255);
                    dst[1] = (unsigned char)((cg * a + dst[1] * (255 - a)) / 255);
                    dst[2] = (unsigned char)((cr * a + dst[2] * (255 - a)) / 255);
                    dst[3] = 255;
                }
            }
            stbtt_FreeBitmap(bm, NULL);
        }
        pen += (float)adv * scale;
    }
}

static void
draw_centered(struct recovery *r, const char *s, int y, int px,
              int cr, int cg, int cb)
{
    float w = 0;
    text_width(r, s, px, &w, NULL);
    draw_text(r, s, (int)((r->width - w) * 0.5f), y, px, cr, cg, cb);
}

/* ── log reading ─────────────────────────────────────────────────────────── */

static void
load_log_list(struct recovery *r)
{
    r->log_count = 0;
    DIR *d = opendir("/data/log");
    if (!d)
        return;

    struct dirent *e;
    while (r->log_count < MAX_LOGS && (e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        size_t n = strlen(e->d_name);
        if (n >= sizeof(r->log_name[0]))
            n = sizeof(r->log_name[0]) - 1;
        memcpy(r->log_name[r->log_count], e->d_name, n);
        r->log_name[r->log_count][n] = '\0';
        r->log_count++;
    }
    closedir(d);
}

static void
load_log_file(struct recovery *r, const char *name)
{
    r->log_line_count = 0;
    r->log_scroll = 0;

    char path[160];
    snprintf(path, sizeof(path), "/data/log/%s", name);

    FILE *f = fopen(path, "r");
    if (!f)
        return;

    free(r->log_buf);
    r->log_buf = malloc(256 * 1024);
    if (!r->log_buf) {
        fclose(f);
        return;
    }

    size_t n = fread(r->log_buf, 1, 256 * 1024 - 1, f);
    fclose(f);
    r->log_buf[n] = '\0';

    char *p = r->log_buf;
    while (p && *p && r->log_line_count < LOG_LINES) {
        char *nl = strchr(p, '\n');
        if (nl)
            *nl = '\0';
        r->log_lines[r->log_line_count++] = p;
        p = nl ? nl + 1 : NULL;
    }
}

/* ── menu drawing ────────────────────────────────────────────────────────── */

static const char *const menu_items[] = {
    "REBOOT", "SHUTDOWN", "FACTORY RESET", "ROLLBACK", "VIEW LOGS",
};
#define MENU_COUNT ((int)(sizeof(menu_items) / sizeof(menu_items[0])))

static void
redraw(struct recovery *r)
{
    fill_rect(r, 0, 0, r->width, r->height, CLR_BG_R, CLR_BG_G, CLR_BG_B);

    int px_title = (int)(r->height * 0.045f);
    int px_item  = (int)(r->height * 0.032f);
    int px_hint  = (int)(r->height * 0.020f);

    if (r->mode == MODE_MENU || r->mode == MODE_CONFIRM) {
        draw_centered(r, "RECOVERY MODE", (int)(r->height * 0.20f),
                      px_title, 255, 255, 255);

        int y = (int)(r->height * 0.36f);
        int step = (int)(px_item * 2.1f);
        for (int i = 0; i < MENU_COUNT; i++) {
            bool sel = (i == r->cursor);
            float w = 0;
            text_width(r, menu_items[i], px_item, &w, NULL);
            int x = (int)((r->width - w) * 0.5f);

            if (sel) {
                int pad_x = px_item;
                int pad_y = (int)(px_item * 0.20f);
                fill_rect(r, x - pad_x, y - pad_y,
                          (int)w + pad_x * 2, px_item + pad_y * 2,
                          CLR_HL_R, CLR_HL_G, CLR_HL_B);
            }
            draw_text(r, menu_items[i], x, y, px_item,
                      sel ? 255 : 210, sel ? 255 : 214, sel ? 255 : 228);
            y += step;
        }

        const char *hint = "D-PAD: NAVIGATE    A: SELECT    B: BACK";
        draw_centered(r, hint, r->height - (int)(px_hint * 3.2f), px_hint,
                      150, 158, 175);

        if (r->mode == MODE_CONFIRM)
            draw_centered(r, r->confirm_text, (int)(r->height * 0.74f),
                          px_item, 255, 190, 90);

        if (r->toast[0])
            draw_centered(r, r->toast, (int)(r->height * 0.80f), px_hint,
                          255, 190, 90);
    } else if (r->mode == MODE_LOGLIST) {
        draw_centered(r, "SYSTEM LOGS", (int)(r->height * 0.10f),
                      px_title, 255, 255, 255);

        int y = (int)(r->height * 0.24f);
        int step = (int)(px_item * 1.7f);
        int first = r->log_cursor > 12 ? r->log_cursor - 12 : 0;
        for (int i = first; i < r->log_count && i < first + 14; i++) {
            bool sel = (i == r->log_cursor);
            if (sel)
                fill_rect(r, (int)(r->width * 0.18f), y - 4,
                          (int)(r->width * 0.64f), px_item + 8,
                          CLR_HL_R, CLR_HL_G, CLR_HL_B);
            draw_text(r, r->log_name[i], (int)(r->width * 0.20f), y, px_item,
                      sel ? 255 : 210, sel ? 255 : 214, sel ? 255 : 228);
            y += step;
        }
        if (r->log_count == 0)
            draw_centered(r, "NO LOGS FOUND", (int)(r->height * 0.5f),
                          px_item, 200, 200, 200);

        draw_centered(r, "A: VIEW    B: BACK", r->height - (int)(px_hint * 3.2f),
                      px_hint, 150, 158, 175);
    } else {
        /* MODE_LOGVIEW */
        draw_centered(r, r->log_name[r->log_cursor < r->log_count
                                        ? r->log_cursor : 0],
                      (int)(r->height * 0.06f), px_title, 255, 255, 255);

        int y = (int)(r->height * 0.15f);
        int step = (int)(px_hint * 1.25f);
        int lines = (r->height - y - (int)(px_hint * 4)) / (step ? step : 1);
        if (lines > LOG_VIEW_LINES)
            lines = LOG_VIEW_LINES;

        for (int i = 0; i < lines; i++) {
            int idx = r->log_scroll + i;
            if (idx >= r->log_line_count)
                break;
            /* the shell's logs start with a "[ uptime ]" prefix; keep it, it is
             * the only time reference in them */
            draw_text(r, r->log_lines[idx], (int)(r->width * 0.04f), y,
                      px_hint, 214, 220, 235);
            y += step;
        }
        draw_centered(r, "UP/DOWN: SCROLL    B: BACK",
                      r->height - (int)(px_hint * 3.2f), px_hint, 150, 158, 175);
    }
}

/* ── wayland plumbing ────────────────────────────────────────────────────── */

static void
wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial)
{
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
    .ping = wm_base_ping,
};

static void
xdg_surface_configure(void *data, struct xdg_surface *s, uint32_t serial)
{
    struct recovery *r = data;
    xdg_surface_ack_configure(s, serial);
    r->configured = true;
    r->dirty = true;
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static void
toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h,
                   struct wl_array *states)
{
    (void)t;
    (void)states;
    struct recovery *r = data;
    if (w > 0 && h > 0) {
        r->width = w;
        r->height = h;
        r->dirty = true;
    }
}

static void
toplevel_close(void *data, struct xdg_toplevel *t)
{
    (void)t;
    struct recovery *r = data;
    r->running = false;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
};

static void
registry_global(void *data, struct wl_registry *reg, uint32_t name,
                const char *interface, uint32_t version)
{
    struct recovery *r = data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        r->compositor = wl_registry_bind(reg, name,
                                         &wl_compositor_interface,
                                         version < 4 ? version : 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        r->shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        r->wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(r->wm_base, &wm_base_listener, r);
    }
}

static void
registry_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
    (void)data;
    (void)reg;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static bool
allocate_buffer(struct recovery *r)
{
    r->stride = r->width * 4;
    r->pixels_size = (size_t)r->stride * (size_t)r->height;

    int fd = create_shm_file(r->pixels_size);
    if (fd < 0)
        return false;

    r->pixels = mmap(NULL, r->pixels_size, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, 0);
    if (r->pixels == MAP_FAILED) {
        close(fd);
        r->pixels = NULL;
        return false;
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(r->shm, fd,
                                                  (int32_t)r->pixels_size);
    r->buffer = wl_shm_pool_create_buffer(pool, 0, r->width, r->height,
                                          r->stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    if (r->buffer)
        wl_buffer_add_listener(r->buffer, &buffer_listener, r);
    return r->buffer != NULL;
}

static void
frame_done(void *data, struct wl_callback *cb, uint32_t t)
{
    (void)t;
    struct recovery *r = data;
    wl_callback_destroy(cb);
    r->frame_cb = NULL;
    if (r->dirty)
        wl_surface_commit(r->surface);
}

static const struct wl_callback_listener frame_listener = {
    .done = frame_done,
};

/* Paint and submit one frame. The buffer is owned by the compositor until it
 * sends wl_buffer.release, so we only paint into a free one. */
static void
present(struct recovery *r)
{
    if (!r->pixels || r->buffer_busy)
        return;
    if (!r->buffer && !allocate_buffer(r))
        return;

    redraw(r);

    wl_surface_attach(r->surface, r->buffer, 0, 0);
    wl_surface_damage_buffer(r->surface, 0, 0, r->width, r->height);
    r->buffer_busy = true;
    r->dirty = false;

    if (!r->frame_cb) {
        r->frame_cb = wl_surface_frame(r->surface);
        wl_callback_add_listener(r->frame_cb, &frame_listener, r);
    }
    wl_surface_commit(r->surface);
}

/* ── actions ─────────────────────────────────────────────────────────────── */

static void
activate(struct recovery *r)
{
    switch (r->cursor) {
    case 0:
        playos_trusted_reboot(-1);
        break;
    case 1:
        playos_trusted_shutdown(-1);
        break;
    case 2:
        snprintf(r->confirm_text, sizeof(r->confirm_text),
                 "FACTORY RESET?  A: CONFIRM   B: CANCEL");
        r->mode = MODE_CONFIRM;
        break;
    case 3:
        playos_trusted_rollback_slot(-1);
        break;
    case 4:
        load_log_list(r);
        r->log_cursor = 0;
        r->mode = MODE_LOGLIST;
        break;
    }
    r->dirty = true;
}

/* ── input ───────────────────────────────────────────────────────────────── */

static bool
evdev_wanted(int fd)
{
    unsigned char abs[(ABS_MAX / 8) + 1];
    unsigned char key[(KEY_MAX / 8) + 1];
    memset(abs, 0, sizeof(abs));
    memset(key, 0, sizeof(key));

    if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs)), abs) < 0)
        return false;
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key)), key) < 0)
        return false;

    bool hat = (abs[ABS_HAT0X / 8] >> (ABS_HAT0X % 8)) & 1;
    bool south = (key[BTN_SOUTH / 8] >> (BTN_SOUTH % 8)) & 1;
    bool vol = (key[KEY_VOLUMEUP / 8] >> (KEY_VOLUMEUP % 8)) & 1;
    return (hat && south) || (south && vol);
}

static void
add_inputs(struct recovery *r)
{
    for (int i = 0; i < 32 && r->nfds < (int)(sizeof(r->fds) /
                                               sizeof(r->fds[0])); i++) {
        char path[64];
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0)
            continue;
        if (!evdev_wanted(fd)) {
            close(fd);
            continue;
        }
        r->fds[r->nfds].fd = fd;
        r->fds[r->nfds].events = POLLIN;
        r->nfds++;
    }
    fprintf(stderr, "playos-recovery: %d input devices\n", r->nfds);
}

static void
handle_key(struct recovery *r, uint16_t code, int32_t value)
{
    if (value != 1)   /* act on the press edge */
        return;

    if (r->mode == MODE_CONFIRM) {
        if (code == BTN_SOUTH) {
            playos_trusted_factory_reset(-1, 1, 1, 1, 1, 1);
        } else if (code == BTN_EAST) {
            r->mode = MODE_MENU;
            r->confirm_text[0] = '\0';
        }
        r->dirty = true;
        return;
    }

    if (r->mode == MODE_LOGVIEW) {
        if (code == BTN_EAST) {
            r->mode = MODE_LOGLIST;
            r->dirty = true;
        } else if (code == BTN_DPAD_UP || code == KEY_VOLUMEUP) {
            if (r->log_scroll > 0) {
                r->log_scroll--;
                r->dirty = true;
            }
        } else if (code == BTN_DPAD_DOWN || code == KEY_VOLUMEDOWN) {
            if (r->log_scroll + 1 < r->log_line_count) {
                r->log_scroll++;
                r->dirty = true;
            }
        }
        return;
    }

    if (r->mode == MODE_LOGLIST) {
        if (code == BTN_EAST) {
            r->mode = MODE_MENU;
        } else if (code == BTN_DPAD_UP || code == KEY_VOLUMEUP) {
            if (r->log_cursor > 0)
                r->log_cursor--;
        } else if (code == BTN_DPAD_DOWN || code == KEY_VOLUMEDOWN) {
            if (r->log_cursor + 1 < r->log_count)
                r->log_cursor++;
        } else if (code == BTN_SOUTH && r->log_cursor < r->log_count) {
            load_log_file(r, r->log_name[r->log_cursor]);
            r->mode = MODE_LOGVIEW;
        }
        r->dirty = true;
        return;
    }

    /* menu */
    if (code == BTN_DPAD_UP || code == KEY_VOLUMEUP) {
        r->cursor = (r->cursor + MENU_COUNT - 1) % MENU_COUNT;
        r->dirty = true;
    } else if (code == BTN_DPAD_DOWN || code == KEY_VOLUMEDOWN) {
        r->cursor = (r->cursor + 1) % MENU_COUNT;
        r->dirty = true;
    } else if (code == BTN_SOUTH) {
        activate(r);
    }
}

/* The ROG Ally's d-pad arrives as ABS_HAT0X/ABS_HAT0Y, not BTN_DPAD_*. Track the
 * axis value so each step produces exactly one movement. */
static int last_hat_y = 0;

static void
handle_abs(struct recovery *r, uint16_t code, int32_t value)
{
    if (code != ABS_HAT0Y)
        return;
    if (value == last_hat_y)
        return;

    if (value > 0)
        handle_key(r, BTN_DPAD_DOWN, 1);
    else if (value < 0)
        handle_key(r, BTN_DPAD_UP, 1);
    last_hat_y = value;
}

static void
drain_input(struct recovery *r, int idx)
{
    struct input_event ev;
    for (;;) {
        ssize_t n = read(r->fds[idx].fd, &ev, sizeof(ev));
        if (n < (ssize_t)sizeof(ev))
            break;
        if (ev.type == EV_KEY)
            handle_key(r, ev.code, ev.value);
        else if (ev.type == EV_ABS)
            handle_abs(r, ev.code, ev.value);
    }
}

/* ── font ────────────────────────────────────────────────────────────────── */

static bool
load_font(struct recovery *r)
{
    static const char *const candidates[] = {
        "/usr/share/playos-shell/assets/Silkscreen-Regular.ttf",
        "/usr/share/playos-shell/assets/Silkscreen-Bold.ttf",
        "/usr/share/playos-shell/assets/PressStart2P-Regular.ttf",
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        FILE *f = fopen(candidates[i], "rb");
        if (!f)
            continue;
        fseek(f, 0, SEEK_END);
        long size = ftell(f);
        fseek(f, 0, SEEK_SET);
        r->ttf = malloc((size_t)size);
        if (!r->ttf) {
            fclose(f);
            return false;
        }
        if (fread(r->ttf, 1, (size_t)size, f) != (size_t)size) {
            fclose(f);
            free(r->ttf);
            r->ttf = NULL;
            return false;
        }
        fclose(f);
        if (stbtt_InitFont(&r->font, r->ttf, 0)) {
            fprintf(stderr, "playos-recovery: font %s\n", candidates[i]);
            return true;
        }
        free(r->ttf);
        r->ttf = NULL;
    }
    return false;
}

/* ── main ────────────────────────────────────────────────────────────────── */

int
main(void)
{
    struct recovery r;
    memset(&r, 0, sizeof(r));
    r.running = true;
    r.width = 1920;
    r.height = 1080;

    if (!load_font(&r)) {
        fprintf(stderr, "playos-recovery: no usable font\n");
        return 1;
    }

    r.display = wl_display_connect(NULL);
    if (!r.display) {
        fprintf(stderr, "playos-recovery: cannot connect to the compositor\n");
        return 1;
    }

    r.registry = wl_display_get_registry(r.display);
    wl_registry_add_listener(r.registry, &registry_listener, &r);
    wl_display_roundtrip(r.display);

    if (!r.compositor || !r.shm || !r.wm_base) {
        fprintf(stderr, "playos-recovery: compositor lacks wl_compositor/wl_shm/"
                        "xdg_wm_base\n");
        return 1;
    }

    r.surface = wl_compositor_create_surface(r.compositor);
    r.xsurface = xdg_wm_base_get_xdg_surface(r.wm_base, r.surface);
    xdg_surface_add_listener(r.xsurface, &xdg_surface_listener, &r);
    r.toplevel = xdg_surface_get_toplevel(r.xsurface);
    xdg_toplevel_add_listener(r.toplevel, &toplevel_listener, &r);
    xdg_toplevel_set_title(r.toplevel, "PlayOS Recovery");
    xdg_toplevel_set_app_id(r.toplevel, "org.playos.recovery");
    xdg_toplevel_set_fullscreen(r.toplevel, NULL);
    wl_surface_commit(r.surface);

    /* Wait (briefly) for the configure that tells us the output size. */
    for (int i = 0; i < 50 && !r.configured; i++) {
        wl_display_dispatch(r.display);
        wl_display_flush(r.display);
    }
    fprintf(stderr, "playos-recovery: surface %dx%d (configured=%d)\n",
            r.width, r.height, (int)r.configured);

    if (!allocate_buffer(&r)) {
        fprintf(stderr, "playos-recovery: shm buffer allocation failed\n");
        return 1;
    }

    add_inputs(&r);
    r.dirty = true;
    present(&r);
    wl_display_flush(r.display);

    while (r.running) {
        struct pollfd fds[17];
        int n = 1;
        fds[0].fd = wl_display_get_fd(r.display);
        fds[0].events = POLLIN;
        for (int i = 0; i < r.nfds; i++)
            fds[n++] = r.fds[i];

        if (poll(fds, n, 1000) < 0) {
            if (errno == EINTR)
                continue;
            break;
        }

        if (fds[0].revents & POLLIN) {
            if (wl_display_dispatch(r.display) < 0)
                break;
        }
        for (int i = 0; i < r.nfds; i++) {
            if (fds[1 + i].revents & POLLIN)
                drain_input(&r, i);
        }

        /* wl_buffer.release clears buffer_busy, so a dirty UI always redraws
         * on the next pass instead of piling up buffers. */
        if (r.dirty)
            present(&r);
        wl_display_flush(r.display);
    }

    wl_display_disconnect(r.display);
    return 0;
}
