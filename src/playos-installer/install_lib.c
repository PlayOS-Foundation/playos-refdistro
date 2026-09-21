/* install_lib.c — the PlayOS install engine (Sprint 14.5, T1).
 *
 * The step bodies are the pre-14.5 installer's, moved verbatim where possible so
 * the install behaves identically: same order, same commands, same messages.
 * What is new is that the engine takes a context instead of the installer's UI
 * state, and reports through callbacks. */
#include "install_lib.h"

#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>

#include "efi.h"
#include "format.h"

const char *const playos_install_step_names[PLAYOS_INSTALL_STEP_COUNT] = {
    "Create GPT", "Format ESP", "Write system A", "Reserve system B",
    "Format misc", "Format data", "Write EFI", "Sync"
};

/* The engine owns the mountpoints it mounts onto. The standalone front-end used to
 * create them in its main(), which meant a second front-end (the screen-less
 * worker) had to know that too - and it did not: step 6 died with
 * "mount /dev/nvme0n1p1: No such file or directory" because /mnt/efi was missing,
 * not the device. Creating them here makes both front-ends self-sufficient;
 * mkdir on an existing directory is harmless.
 *
 * Audited against the engine's own code: efi.c mounts /mnt/efi; the payload is
 * mounted by the caller (/mnt/payload, also created by init) and the front-end's
 * seed-key callback owns /mnt/payload-data. */
static void
ensure_mountpoints(void)
{
    (void)mkdir("/mnt", 0755);
    (void)mkdir("/mnt/efi", 0755);
    (void)mkdir("/mnt/payload", 0755);
    (void)mkdir("/mnt/payload-data", 0755);
}

/* The step log lines are byte-identical to the pre-14.5 installer's, so existing
 * logs, docs and comparisons keep working. */
static void
ilog(struct playos_install_ctx *ctx, const char *fmt, ...)
{
    if (!ctx->log)
        return;

    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);

    ctx->log(ctx->log_ud, line);
}

void
playos_install_ctx_init(struct playos_install_ctx *ctx,
                        const char *target_device,
                        const char *payload_mount)
{
    memset(ctx, 0, sizeof(*ctx));
    ctx->target_device = target_device;
    ctx->payload_mount = payload_mount;

    /* Normalise once, at the boundary: every step helper builds "/dev/<name>". */
    const char *name = target_device ? target_device : "";
    if (strncmp(name, "/dev/", 5) == 0)
        name += 5;
    snprintf(ctx->device, sizeof(ctx->device), "%s", name);
    ctx->step_error = -1;
    snprintf(ctx->step_name, sizeof(ctx->step_name), "%s",
             playos_install_step_names[0]);
}

int
playos_install_run_step(struct playos_install_ctx *ctx)
{
    const char *dev = ctx->device;
    char *err = ctx->err;
    size_t errlen = sizeof(ctx->err);
    int rc = 0;

    if (ctx->step_index < 0 || ctx->step_index >= PLAYOS_INSTALL_STEP_COUNT) {
        snprintf(err, errlen, "invalid step index %d", ctx->step_index);
        ctx->step_error = -1;
        return -1;
    }

    snprintf(ctx->step_name, sizeof(ctx->step_name), "%s",
             playos_install_step_names[ctx->step_index]);

    ensure_mountpoints();

    ilog(ctx, "installer step %d/8 %s: begin (target=%s)",
         ctx->step_index, ctx->step_name, dev);

    switch (ctx->step_index) {
    case 0:
        /* Make the target free first: a partition of it staying mounted (the
         * ESP is mounted as /EFI by init on a live session) makes mkfs refuse
         * the format and the kernel refuse to re-read the partition table. */
        if (playos_format_release_target(dev, err, errlen) != 0) {
            rc = -1;
            break;
        }
        ilog(ctx, "installer: target %s is free of mounts", dev);
        rc = playos_format_partition_disk(dev, err, errlen);
        break;
    case 1: rc = playos_format_mkfs_fat(dev, 1, "ESP", err, errlen); break;
    case 2: rc = playos_format_write_image(dev, 2, "/mnt/payload/rootfs.squashfs",
                                           err, errlen); break;
    case 3: rc = 0; break; /* system B is reserved for a future OTA */
    case 4: rc = playos_format_mkfs_ext4(dev, 4, "misc", err, errlen); break;
    case 5:
        rc = playos_format_mkfs_ext4(dev, 5, "playos-data", err, errlen);
        if (rc == 0 && ctx->resolve_seed_key) {
            /* /data is unmounted by init before the installer spawns, so the
             * live session's key is not visible here; which source to use (and
             * whether to mount the boot medium's own playos-data for it) is
             * front-end policy, so it arrives through the callback. */
            char src[192] = {0};
            int mounted = 0;
            int present = 0;

            (void)ctx->resolve_seed_key(ctx->seed_ud, src, sizeof(src),
                                        &mounted, &present);
            fprintf(stdout, "AUTO: payload-data: step5 src=%s key_present=%d\n",
                    src, present);
            rc = playos_format_seed_ssh_keys(dev, 5, src, err, errlen);
            ilog(ctx, "installer step 5/8 Format data: ssh key source %s, seed rc=%d",
                 present ? "present" : "absent", rc);
            if (mounted && ctx->release_seed_key)
                ctx->release_seed_key(ctx->seed_ud);
        }
        break;
    case 6: rc = playos_efi_write(dev, ctx->payload_mount, err, errlen); break;
    case 7: playos_format_sync(); rc = 0; break;
    default: rc = -1; break;
    }

    if (rc != 0) {
        ilog(ctx, "installer step %d/8 %s: FAILED: %s",
             ctx->step_index, ctx->step_name, err);
        ctx->step_error = ctx->step_index;
        return -1;
    }

    ilog(ctx, "installer step %d/8 %s: ok", ctx->step_index, ctx->step_name);
    ctx->step_index++;
    return 0;
}

int
playos_install_run_all(struct playos_install_ctx *ctx)
{
    while (ctx->step_index < PLAYOS_INSTALL_STEP_COUNT) {
        if (playos_install_run_step(ctx) != 0)
            return -1;
    }
    return 0;
}
