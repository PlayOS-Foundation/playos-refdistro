/* install_lib.h — the PlayOS install engine (Sprint 14.5, T1).
 *
 * The engine owns the step sequence and the ordering of destructive work. It has
 * no UI, no logging sink of its own and no knowledge of how progress is shown:
 * the caller supplies an optional log sink, an optional sub-step progress sink
 * and a callback to resolve the SSH key that should be seeded into a fresh
 * install (which involves mounting the boot medium's data partition — policy the
 * front-ends own, not the engine).
 *
 * Two front-ends use this: the standalone installer (playos-installer, which
 * draws its own UI) and the screen-less playos-install-worker, which reports
 * progress over the trusted socket.
 *
 * Step names and the per-step log lines are kept byte-identical to the
 * pre-14.5 installer so existing logs, docs and comparisons keep working. */
#ifndef PLAYOS_INSTALL_LIB_H
#define PLAYOS_INSTALL_LIB_H

#include <stddef.h>

#define PLAYOS_INSTALL_STEP_COUNT 8

extern const char *const playos_install_step_names[PLAYOS_INSTALL_STEP_COUNT];

struct playos_install_ctx {
    /* What to install, and where the payload lives. */
    const char *target_device;      /* e.g. /dev/nvme0n1 */
    const char *payload_mount;      /* e.g. /mnt/payload (rootfs.squashfs + BOOTX64*.EFI) */

    /* Progress state, owned by the engine. */
    int  step_index;                /* 0-based; the engine advances it */
    int  step_error;                /* -1 when none, else the failing index */
    char step_name[64];
    char err[512];

    /* Optional reporting sinks. */
    void (*log)(void *ud, const char *line);
    void *log_ud;

    /* Sub-step progress for the payload write (bytes written / total). */
    void (*progress)(void *ud, unsigned long long done, unsigned long long total);
    void *progress_ud;

    /* Resolve the authorized_keys file to seed into a new install. Return 0 and
     * fill `path` with the source to try and set *present when that file exists;
     * set *mounted nonzero when the caller mounted something that
     * `release_seed_key` must unmount. Always returns 0. Optional: without it no
     * key is seeded. */
    int  (*resolve_seed_key)(void *ud, char *path, size_t path_sz,
                             int *mounted, int *present);
    void (*release_seed_key)(void *ud);
    void *seed_ud;
};

void playos_install_ctx_init(struct playos_install_ctx *ctx,
                             const char *target_device,
                             const char *payload_mount);

/* Run the step at ctx->step_index. Returns 0 on success (advancing step_index),
 * -1 on failure with ctx->err and ctx->step_error set. */
int playos_install_run_step(struct playos_install_ctx *ctx);

/* Run every remaining step. Returns 0 when the whole install succeeded. */
int playos_install_run_all(struct playos_install_ctx *ctx);

#endif /* PLAYOS_INSTALL_LIB_H */
