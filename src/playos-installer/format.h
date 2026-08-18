/**
 * format.h — PlayOS installer GPT partitioning + filesystem/image helpers
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef PLAYOS_INSTALLER_FORMAT_H
#define PLAYOS_INSTALLER_FORMAT_H

#include <stddef.h>

/* Lay down a 5-partition GPT on a whole-disk device:
 *   1 ESP        512 MiB   FAT32 (EFI System Partition)
 *   2 playos-a     4 GiB   ext2  (system slot A, squashfs image written here)
 *   3 playos-b     4 GiB   ext2  (reserved system slot B)
 *   4 misc        64 MiB   ext4
 *   5 playos-data  rest    ext4
 * The device argument is the bare kernel name (e.g. "nvme0n1"). */
int  playos_format_partition_disk(const char *device, char *err, size_t errlen);

int  playos_format_mkfs_fat(const char *device, int partno, const char *label,
                            char *err, size_t errlen);
int  playos_format_mkfs_ext4(const char *device, int partno, const char *label,
                             char *err, size_t errlen);

/* Stream a file into a partition device node (used for rootfs.squashfs). */
int  playos_format_write_image(const char *device, int partno,
                               const char *image_path, char *err, size_t errlen);

/* Build the partition device node path for a whole-disk device. */
void playos_format_partition_path(const char *device, int partno,
                                  char *out, size_t outlen);

void playos_format_sync(void);

#endif /* PLAYOS_INSTALLER_FORMAT_H */
