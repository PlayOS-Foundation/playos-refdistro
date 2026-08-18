/**
 * disk.h — PlayOS installer disk enumeration
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef PLAYOS_INSTALLER_DISK_H
#define PLAYOS_INSTALLER_DISK_H

#include <stddef.h>

struct playos_disk {
    char device[64];               /* e.g. "nvme0n1" or "sda"          */
    char path[128];                /* /dev/nvme0n1                     */
    char model[256];               /* sysfs device/model, else device  */
    unsigned long long size_bytes; /* from /sys/block/<dev>/size * 512 */
    int removable;
    int partitions;
};

/* Enumerate fixed (removable == 0) block devices as install targets. */
int  playos_disk_enumerate(struct playos_disk **out, int *count);
void playos_disk_free(struct playos_disk *disks, int count);

/* Return the names of the partitions of a whole-disk device (from
 * /proc/partitions), e.g. "nvme0n1" -> "nvme0n1p1", "nvme0n1p2", ...
 * Returns the number of names written (0 if none). */
int  playos_disk_list_partitions(const char *device, char (*names)[64], int max_names);

#endif /* PLAYOS_INSTALLER_DISK_H */
