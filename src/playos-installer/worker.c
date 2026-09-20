/* playos-install-worker — the screen-less install engine (Sprint 14.5-T3).
 *
 * Spawned by init when the shell drives an install, with the same environment
 * discipline as the shell (XDG_RUNTIME_DIR, log redirection, supervision). It
 * never creates a Wayland surface: it runs libplayos-install against
 * PLAYOS_INSTALL_TARGET and reports progress over the trusted control socket,
 * where init relays it to the registered shell listener.
 *
 * The payload partition is mounted by init at PLAYOS_INSTALL_PAYLOAD before this
 * starts, so the worker needs no device discovery of its own - that stays in the
 * standalone installer, which is the only front-end that has to find things.
 *
 * It exits without rebooting: the shell offers "Reboot now" so the user decides
 * (the standalone installer reboots instead). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "install_lib.h"
#include "playos-runtime/trusted_control.h"

static void
worker_log(void *ud, const char *line)
{
    (void)ud;
    /* Same text the standalone installer writes, so logs stay comparable. */
    fprintf(stdout, "%s\n", line);
    fflush(stdout);
}

/* The shell-driven flow keeps the dev SSH key at /tmp: init preserves it there
 * before it unmounts /data. The standalone installer can additionally mount the
 * boot medium's own data partition, but a screen-less worker has nobody to ask,
 * so it uses the two paths that need no mounting. */
static int
worker_resolve_seed_key(void *ud, char *path, size_t path_sz,
                        int *mounted, int *present)
{
    (void)ud;

    *mounted = 0;
    snprintf(path, path_sz, "/data/ssh/authorized_keys");
    *present = (access(path, R_OK) == 0);

    if (!*present && access("/tmp/playos-install-authorized_keys", R_OK) == 0) {
        snprintf(path, path_sz, "/tmp/playos-install-authorized_keys");
        *present = 1;
    }
    return 0;
}

static void
worker_release_seed_key(void *ud)
{
    (void)ud;
}

int
main(void)
{
    const char *target = getenv("PLAYOS_INSTALL_TARGET");
    const char *payload = getenv("PLAYOS_INSTALL_PAYLOAD");

    if (!payload || !payload[0])
        payload = "/mnt/payload";

    if (!target || !target[0]) {
        fprintf(stderr, "playos-install-worker: PLAYOS_INSTALL_TARGET is not set\n");
        return 2;
    }
    if (access(payload, F_OK) != 0) {
        fprintf(stderr, "playos-install-worker: payload %s is not mounted\n", payload);
        return 2;
    }

    struct playos_install_ctx ctx;
    playos_install_ctx_init(&ctx, target, payload);
    ctx.log = worker_log;
    ctx.resolve_seed_key = worker_resolve_seed_key;
    ctx.release_seed_key = worker_release_seed_key;

    fprintf(stdout, "playos-install-worker: install to %s (payload %s)\n",
            target, payload);
    fflush(stdout);

    while (ctx.step_index < PLAYOS_INSTALL_STEP_COUNT) {
        int step = ctx.step_index;
        const char *name = playos_install_step_names[step];

        /* Report the step that is about to run, then the bar's advance, so the
         * shell shows movement during a slow step (the payload write) rather
         * than only between steps. */
        (void)playos_trusted_install_progress(-1, step,
                                              (step * 100) / PLAYOS_INSTALL_STEP_COUNT,
                                              name);

        if (playos_install_run_step(&ctx) != 0) {
            fprintf(stderr, "playos-install-worker: step %d (%s) failed: %s\n",
                    step, name, ctx.err);
            fflush(stderr);
            (void)playos_trusted_install_error(-1, step, ctx.err);
            return 1;
        }

        (void)playos_trusted_install_progress(-1, ctx.step_index,
                                              (ctx.step_index * 100) / PLAYOS_INSTALL_STEP_COUNT,
                                              name);
    }

    fprintf(stdout, "playos-install-worker: install complete\n");
    fflush(stdout);
    (void)playos_trusted_install_complete(-1);
    return 0;
}
