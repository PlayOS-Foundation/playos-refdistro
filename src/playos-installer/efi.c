/**
 * efi.c — PlayOS installer EFI system partition writer
 *
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>

#include "efi.h"
#include "format.h"

static int
copy_file(const char *src, const char *dst, char *err, size_t errlen)
{
    int in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0) {
        snprintf(err, errlen, "open %s: %s", src, strerror(errno));
        return -1;
    }

    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out < 0) {
        snprintf(err, errlen, "open %s: %s", dst, strerror(errno));
        close(in);
        return -1;
    }

    char buf[65536];
    ssize_t n;
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR)
                    continue;
                snprintf(err, errlen, "write %s: %s", dst, strerror(errno));
                close(in);
                close(out);
                return -1;
            }
            off += w;
        }
    }
    if (n < 0) {
        snprintf(err, errlen, "read %s: %s", src, strerror(errno));
        close(in);
        close(out);
        return -1;
    }

    fsync(out);
    close(in);
    close(out);
    return 0;
}

static void
efibootmgr_best_effort(const char *device)
{
    char devpath[128];
    snprintf(devpath, sizeof(devpath), "/dev/%s", device);

    pid_t pid = fork();
    if (pid < 0)
        return;
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        setenv("PATH", "/sbin:/usr/sbin:/bin:/usr/bin", 1);
        char *argv[] = {
            "efibootmgr", "--create", "--disk", devpath, "--part", "1",
            "--label", "PlayOS", "--loader", "\\EFI\\BOOT\\BOOTX64.EFI", NULL
        };
        execvp(argv[0], argv);
        _exit(127);
    }

    int status;
    (void)waitpid(pid, &status, 0);
}

int
playos_efi_write(const char *device, const char *payload_mount,
                 char *err, size_t errlen)
{
    char part[128];
    playos_format_partition_path(device, 1, part, sizeof(part));

    if (mount(part, "/mnt/efi", "vfat", 0, NULL) != 0) {
        snprintf(err, errlen, "mount %s: %s", part, strerror(errno));
        return -1;
    }

    (void)mkdir("/mnt/efi/EFI", 0755);
    (void)mkdir("/mnt/efi/EFI/BOOT", 0755);

    char src[512];
    char dst[512];
    snprintf(src, sizeof(src), "%s/BOOTX64.EFI", payload_mount);
    snprintf(dst, sizeof(dst), "/mnt/efi/EFI/BOOT/BOOTX64.EFI");

    int rc = copy_file(src, dst, err, errlen);

    sync();
    (void)umount("/mnt/efi");

    if (rc != 0)
        return -1;

    /* A removable-media boot entry may not be wanted here, but recording one
     * is harmless and helps UEFI implementations that do not scan the
     * removable fallback path. Failure is non-fatal. */
    efibootmgr_best_effort(device);

    return 0;
}
