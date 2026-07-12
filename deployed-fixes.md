# PlayOS Deployed Fixes — ROG Ally PXE Boot

> **Status:** Working (2026-07-12)  
> **Build:** v45 (ISO at `/srv/playos-pxe/`)
> **Device:** ASUS ROG Ally (Phoenix1 / Radeon 780M)

---

## Quick Fix (apply on booted Ally when GPU fails)

When the Ally boots to a black screen, SSH in and run:

```bash
# 1. Copy fixes from build VM (192.168.10.89)
scp -o StrictHostKeyChecking=no root@192.168.10.89:/var/tmp/playos-archiso-work/x86_64/airootfs/etc/initcpio/fixups/drm_exec.ko /tmp/
scp -o StrictHostKeyChecking=no root@192.168.10.89:/var/tmp/playos-archiso-work/x86_64/airootfs/etc/initcpio/fixups/firmware/amdgpu/*.bin.zst /tmp/

# 2. Stage firmware + bind mount
mkdir -p /run/fixup-firmware/amdgpu
mv /tmp/*.bin.zst /run/fixup-firmware/amdgpu/
mv /tmp/drm_exec.ko /run/fixup-firmware/
mount --bind /run/fixup-firmware/amdgpu /usr/lib/firmware/amdgpu

# 3. Replace corrupted drm_exec with fixed version
modprobe -r amdgpu
modprobe -r drm_exec
insmod /run/fixup-firmware/drm_exec.ko

# 4. Load amdgpu (now finds fixed firmware + drm_exec)
modprobe amdgpu

# 5. Max backlight + restart compositor
echo 64250 > /sys/class/backlight/amdgpu_bl1/brightness
systemctl restart playos-compositor
```

---

## Root Causes

### 1. `mkfs.erofs` small-file corruption
The archiso build uses EROFS for the AI rootfs. EROFS corrupts some small files (notably kernel modules and firmware). This is a bug in mkfs.erofs or the way mkarchiso invokes it.

**Affected files:**
- `/usr/lib/modules/*/kernel/drivers/gpu/drm/drm_exec.ko.zst` (4KB → corrupted)
- `/usr/lib/firmware/amdgpu/gc_11_0_1_imu.bin.zst` and possibly others

**Evidence:** Files are valid in work dir (`/var/tmp/playos-archiso-work/`) but corrupted in the final EROFS (`/srv/playos-pxe/arch/x86_64/airootfs.erofs`).

### 2. No `ipconfig` binary
The `archiso_pxe_common` hook calls `ipconfig` which doesn't exist on the build system. Removed from HOOKS.

### 3. `busybox udhcpc` raw socket failure
busybox's udhcpc can't use raw sockets in this initramfs environment. Replaced with `dhcpcd`.

### 4. USB Ethernet initialization race
On the ROG Ally, the r8152 USB Ethernet takes several seconds to appear after udev loads the driver. Added a 10-second wait loop in `playos-net` hook.

### 5. Network not ready when curl runs
dhcpcd configures the IP but the route/DNS isn't immediately available. Added ping verification before returning from `playos-net`.

---

## Permanent Fix (baked into ISO v45)

### Files bundled in initramfs (workaround for EROFS corruption)

| File | Purpose |
|------|---------|
| `fixup/drm_exec.ko` | Uncorrupted decompressed drm_exec kernel module |
| `fixup/firmware/amdgpu/gc_11_0_1_*.bin.zst` | Phoenix1 GPU firmware (8 files) |
| `fixup/firmware/amdgpu/psp_13_0_0_*.bin.zst` | PSP firmware (4 files) |
| `fixup/firmware/amdgpu/psp_13_0_4_*.bin.zst` | PSP firmware (2 files) |
| `fixup/firmware/amdgpu/smu_13_0_0*.bin.zst` | SMU firmware (2 files) |
| `fixup/firmware/amdgpu/sdma_6_0_*.bin.zst` | SDMA firmware (2 files) |
| `fixup/firmware/amdgpu/vcn_4_0_0.bin.zst` | VCN firmware (2 files) |

### Boot flow

1. **initramfs hook** (`playos-net`): Stages fixup files to `/run/fixup-firmware/` (preserved across switch_root)
2. **systemd service** (`playos-erofs-fixup.service` at sysinit.target):
   - `insmod /run/fixup-firmware/drm_exec.ko`
   - `mount --bind /run/fixup-firmware/amdgpu /usr/lib/firmware/amdgpu`
3. **udev triggers**: amdgpu loads with fixed firmware and drm_exec
4. **Compositor starts**: Hardware rendering on AMD GPU

### Known remaining issue

The `playos-erofs-fixup.sh` script ITSELF may be corrupted by EROFS (it's a small file at 210 bytes). If the systemd service fails with `status=203/EXEC`, apply the manual fix above and rebuild with the script bundled in the initramfs as well.

---

## Key Files Modified

| File | Change |
|------|--------|
| `archiso/profiles/playos/airootfs/etc/mkinitcpio.conf.d/archiso.conf` | Added HOOKS, MODULES, BINARIES |
| `archiso/profiles/playos/airootfs/etc/initcpio/hooks/playos-net` | DHCP + EROFS fixup staging |
| `archiso/profiles/playos/airootfs/etc/initcpio/install/playos-net` | Bundles drm_exec + firmware |
| `archiso/profiles/playos/airootfs/etc/initcpio/fixups/` | Fixed drm_exec.ko + Phoenix1 firmware |
| `archiso/profiles/playos/airootfs/etc/systemd/system/playos-erofs-fixup.service` | systemd service for bind-mount |
| `archiso/profiles/playos/airootfs/usr/lib/playos/erofs-fixup.sh` | Fixup script |
| `archiso/profiles/playos/packages.x86_64` | Added dhcpcd |
| `archiso/profiles/playos/grub/grub.cfg` (PXE version) | `ip=dhcp rd.debug` |

---

## PXE Server (192.168.10.89)

| Component | Config |
|-----------|--------|
| dnsmasq | DHCP 192.168.10.200-210, TFTP `/srv/playos-pxe`, boot `bootx64.efi` |
| nginx | HTTP on :8080, root `/srv/playos-pxe` |
| GRUB | `/srv/playos-pxe/grub/grub.cfg`, netboot EFI with efinet/http/tftp |
