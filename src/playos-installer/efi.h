/**
 * efi.h — PlayOS installer EFI system partition writer
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef PLAYOS_INSTALLER_EFI_H
#define PLAYOS_INSTALLER_EFI_H

#include <stddef.h>

/* Mount partition 1 of the target device, install EFI/BOOT/BOOTX64.EFI from
 * the mounted payload, sync/unmount, then attempt a best-effort efibootmgr
 * NVRAM entry. Returns 0 on success (efibootmgr failure is non-fatal). */
int  playos_efi_write(const char *device, const char *payload_mount,
                      char *err, size_t errlen);

#endif /* PLAYOS_INSTALLER_EFI_H */
