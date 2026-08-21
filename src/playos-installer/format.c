/**
 * format.c — PlayOS installer GPT partitioning + filesystem/image helpers
 *
 * GPT partitioning uses util-linux libfdisk. Filesystem creation and the
 * squashfs image copy are done through the standard mkfs.* / blockdev tools
 * via fork/exec, with stdout/stderr discarded.
 *
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>

#include <libfdisk/libfdisk.h>

#include "format.h"

/* ── child-process helpers ─────────────────────────────────────────────── */

static void
child_redirect_to_devnull(void)
{
    int devnull = open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (devnull >= 0) {
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        close(devnull);
    }
    setenv("PATH", "/sbin:/usr/sbin:/bin:/usr/bin", 1);
}

static int
run_cmd(char *const argv[], char *err, size_t errlen)
{
    pid_t pid = fork();
    if (pid < 0) {
        snprintf(err, errlen, "fork failed: %s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        child_redirect_to_devnull();
        execvp(argv[0], argv);
        _exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        snprintf(err, errlen, "waitpid failed: %s", strerror(errno));
        return -1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        snprintf(err, errlen, "%s failed (exit %d)",
                 argv[0], WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        return -1;
    }
    return 0;
}

static void
run_cmd_best_effort(char *const argv[])
{
    pid_t pid = fork();
    if (pid < 0)
        return;
    if (pid == 0) {
        child_redirect_to_devnull();
        execvp(argv[0], argv);
        _exit(127);
    }
    int status;
    (void)waitpid(pid, &status, 0);
}

/* ── partition device node path ────────────────────────────────────────── */

void
playos_format_partition_path(const char *device, int partno,
                             char *out, size_t outlen)
{
    size_t len = strlen(device);
    char last = len ? device[len - 1] : '\0';
    if (last >= '0' && last <= '9')
        snprintf(out, outlen, "/dev/%sp%d", device, partno);
    else
        snprintf(out, outlen, "/dev/%s%d", device, partno);
}

/* ── filesystem creation ───────────────────────────────────────────────── */

int
playos_format_mkfs_fat(const char *device, int partno, const char *label,
                       char *err, size_t errlen)
{
    char part[128];
    playos_format_partition_path(device, partno, part, sizeof(part));

    char *argv[] = { "mkfs.fat", "-F", "32", "-n", (char *)label, part, NULL };
    return run_cmd(argv, err, errlen);
}

int
playos_format_mkfs_ext4(const char *device, int partno, const char *label,
                        char *err, size_t errlen)
{
    char part[128];
    playos_format_partition_path(device, partno, part, sizeof(part));

    char *argv[] = { "mkfs.ext4", "-F", "-L", (char *)label, part, NULL };
    return run_cmd(argv, err, errlen);
}

/* ── SSH key seeding ─────────────────────────────────────────────────────
 * The installer runs while the boot medium's playos-data partition is mounted
 * at /data. The developer places their public key on the installer USB at
 * <data>/ssh/authorized_keys. This helper mounts the *target* data partition
 * we just created, copies that key into its /ssh/authorized_keys, and
 * unmounts. The source is optional: with no key present this is a no-op so a
 * stock install still succeeds (it will simply accept no SSH key). */
int
playos_format_seed_ssh_keys(const char *device, int partno,
                            const char *src_keys, char *err, size_t errlen)
{
    char part[128];
    playos_format_partition_path(device, partno, part, sizeof(part));

    const char *mnt = "/mnt/data-target";
    (void)mkdir(mnt, 0755);

    if (mount(part, mnt, "ext4", 0, NULL) != 0) {
        snprintf(err, errlen, "mount %s: %s", part, strerror(errno));
        return -1;
    }

    if (access(src_keys, R_OK) == 0) {
        char dst[256];
        snprintf(dst, sizeof(dst), "%s/ssh", mnt);
        (void)mkdir(dst, 0700);
        snprintf(dst, sizeof(dst), "%s/ssh/authorized_keys", mnt);

        int in = open(src_keys, O_RDONLY | O_CLOEXEC);
        if (in < 0) {
            snprintf(err, errlen, "open %s: %s", src_keys, strerror(errno));
            (void)umount(mnt);
            return -1;
        }
        int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (out < 0) {
            snprintf(err, errlen, "open %s: %s", dst, strerror(errno));
            close(in);
            (void)umount(mnt);
            return -1;
        }

        char buf[4096];
        ssize_t n;
        int rc = 0;
        while ((n = read(in, buf, sizeof(buf))) > 0) {
            ssize_t off = 0;
            while (off < n) {
                ssize_t w = write(out, buf + off, (size_t)(n - off));
                if (w < 0) {
                    if (errno == EINTR)
                        continue;
                    rc = -1;
                    break;
                }
                off += w;
            }
            if (rc)
                break;
        }
        if (n < 0)
            rc = -1;
        close(out);
        close(in);
        if (rc != 0) {
            snprintf(err, errlen, "copy %s -> %s failed", src_keys, dst);
            (void)umount(mnt);
            return -1;
        }
    }

    (void)umount(mnt);
    (void)rmdir(mnt);
    return 0;
}

/* ── image copy ────────────────────────────────────────────────────────── */

int
playos_format_write_image(const char *device, int partno,
                          const char *image_path, char *err, size_t errlen)
{
    char part[128];
    playos_format_partition_path(device, partno, part, sizeof(part));

    int src = open(image_path, O_RDONLY | O_CLOEXEC);
    if (src < 0) {
        snprintf(err, errlen, "open %s: %s", image_path, strerror(errno));
        return -1;
    }

    int dst = open(part, O_WRONLY | O_CLOEXEC);
    if (dst < 0) {
        snprintf(err, errlen, "open %s: %s", part, strerror(errno));
        close(src);
        return -1;
    }

    char buf[1024 * 1024];
    ssize_t n;
    while ((n = read(src, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(dst, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR)
                    continue;
                snprintf(err, errlen, "write %s: %s", part, strerror(errno));
                close(src);
                close(dst);
                return -1;
            }
            off += w;
        }
    }
    if (n < 0) {
        snprintf(err, errlen, "read %s: %s", image_path, strerror(errno));
        close(src);
        close(dst);
        return -1;
    }

    if (fsync(dst) != 0) {
        snprintf(err, errlen, "fsync %s: %s", part, strerror(errno));
        close(src);
        close(dst);
        return -1;
    }

    close(src);
    close(dst);
    return 0;
}

void
playos_format_sync(void)
{
    sync();
}

/* Wipe stale filesystem signatures from the freshly-created partition nodes
 * so a previous install's superblock (an old slot-B or data partition left
 * over from a prior layout) cannot fool blkid into labelling the wrong
 * partition as playos-data. Best effort: some nodes may not exist yet, and
 * not every node carries a signature to wipe. */
static void
playos_format_wipe_partitions(const char *device)
{
    for (int partno = 1; partno <= 5; partno++) {
        char part[128];
        playos_format_partition_path(device, partno, part, sizeof(part));

        char *argv[] = { "wipefs", "-a", part, NULL };
        run_cmd_best_effort(argv);
    }
}

/* ── GPT layout ────────────────────────────────────────────────────────── */

int
playos_format_partition_disk(const char *device, char *err, size_t errlen)
{
    struct fdisk_context *cxt = NULL;
    struct fdisk_label *lb = NULL;
    struct fdisk_parttype *esp_type = NULL;
    struct fdisk_parttype *linux_type = NULL;
    char devpath[128];
    int rc = -1;

    snprintf(devpath, sizeof(devpath), "/dev/%s", device);

    cxt = fdisk_new_context();
    if (!cxt) {
        snprintf(err, errlen, "fdisk_new_context failed");
        return -1;
    }

    if (fdisk_assign_device(cxt, devpath, 0) != 0) {
        snprintf(err, errlen, "fdisk_assign_device(%s): %s",
                 devpath, strerror(errno));
        goto out;
    }

    if (fdisk_create_disklabel(cxt, "gpt") != 0) {
        snprintf(err, errlen, "fdisk_create_disklabel(gpt): %s",
                 strerror(errno));
        goto out;
    }

    lb = fdisk_get_label(cxt, "gpt");
    if (!lb) {
        snprintf(err, errlen, "fdisk_get_label(gpt) failed");
        goto out;
    }

    /* EFI System Partition and Linux filesystem partition type GUIDs. */
    esp_type = fdisk_label_parse_parttype(lb,
        "C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
    linux_type = fdisk_label_parse_parttype(lb,
        "0FC63DAF-8483-4772-8E79-3D69D8477DE4");
    if (!esp_type || !linux_type) {
        snprintf(err, errlen, "fdisk_label_parse_parttype failed");
        goto out;
    }

    /* Never fall back to interactive Ask-API prompts — this installer runs
     * headless (and in the QEMU loopback test there is no controlling tty).
     * With dialogs disabled, libfdisk returns a clean -EINVAL instead of
     * trying to prompt when a parameter is missing. */
    fdisk_disable_dialogs(cxt, 1);

    static const char *const names[5] = {
        "ESP", "playos-a", "playos-b", "misc", "playos-data"
    };
    static const uint64_t sizes[4] = {
        1048576ULL, /* 512 MiB ESP   */
        8388608ULL, /*   4 GiB slot A */
        8388608ULL, /*   4 GiB slot B */
        131072ULL,  /*  64 MiB misc  */
    };

    for (int i = 0; i < 4; i++) {
        struct fdisk_partition *pa = fdisk_new_partition();
        if (!pa) {
            snprintf(err, errlen, "fdisk_new_partition failed (part %d)", i + 1);
            goto out;
        }
        /* This is a one-shot installer process. We deliberately do not unref
         * the partition/parttype objects handed to the context: letting
         * fdisk_unref_context() tear down the context and its table avoids
         * the libfdisk refcount-ordering pitfalls at the cost of a handful
         * of leaked allocations in a process that exits immediately after. */
        (void)fdisk_partition_start_follow_default(pa, 1);
        (void)fdisk_partition_end_follow_default(pa, 0);
        /* Let libfdisk pick the next free GPT partition number (1-based
         * entry index). Without this it would try to prompt for the partno,
         * which is fatal on a headless installer. */
        (void)fdisk_partition_partno_follow_default(pa, 1);
        if (fdisk_partition_set_size(pa, sizes[i]) != 0) {
            snprintf(err, errlen, "fdisk_partition_set_size failed (part %d)",
                     i + 1);
            goto out;
        }
        if (fdisk_partition_set_name(pa, names[i]) != 0) {
            snprintf(err, errlen, "fdisk_partition_set_name failed (part %d)",
                     i + 1);
            goto out;
        }
        if (fdisk_partition_set_type(pa, i == 0 ? esp_type : linux_type) != 0) {
            snprintf(err, errlen, "fdisk_partition_set_type failed (part %d)",
                     i + 1);
            goto out;
        }
        {
            int add_rc = fdisk_add_partition(cxt, pa, NULL);
            if (add_rc != 0) {
                errno = -add_rc;
                snprintf(err, errlen, "fdisk_add_partition failed (part %d): %s",
                         i + 1, strerror(errno));
                goto out;
            }
        }
    }

    /* playos-data: consume the remainder of the disk. */
    {
        struct fdisk_partition *pa = fdisk_new_partition();
        if (!pa) {
            snprintf(err, errlen, "fdisk_new_partition failed (part 5)");
            goto out;
        }
        (void)fdisk_partition_start_follow_default(pa, 1);
        (void)fdisk_partition_end_follow_default(pa, 1);
        (void)fdisk_partition_partno_follow_default(pa, 1);
        (void)fdisk_partition_set_name(pa, names[4]);
        if (fdisk_partition_set_type(pa, linux_type) != 0) {
            snprintf(err, errlen, "fdisk_partition_set_type failed (part 5)");
            goto out;
        }
        {
            int add_rc = fdisk_add_partition(cxt, pa, NULL);
            if (add_rc != 0) {
                errno = -add_rc;
                snprintf(err, errlen, "fdisk_add_partition failed (part 5): %s",
                         strerror(errno));
                goto out;
            }
        }
    }

    if (fdisk_write_disklabel(cxt) != 0) {
        snprintf(err, errlen, "fdisk_write_disklabel: %s", strerror(errno));
        goto out;
    }

    rc = 0;

out:
    if (cxt)
        fdisk_unref_context(cxt);

    if (rc == 0) {
        /* Make the kernel re-read the new partition table so the partition
         * device nodes appear (devtmpfs). Best effort — if this fails the
         * subsequent mkfs steps report the real error. */
        char *reread[] = { "blockdev", "--rereadpt", devpath, NULL };
        run_cmd_best_effort(reread);
        sync();

        /* Clear any stale filesystem signatures the old layout left behind. */
        playos_format_wipe_partitions(device);
    }

    return rc;
}
