# ROG Ally Firmware Requirements

Firmware blobs required for ASUS ROG Ally (2023, AMD Ryzen Z1 Extreme "Phoenix") hardware support.

## Source

All firmware is sourced from the linux-firmware repository:

- **Repository:** https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
- **License:** Proprietary (redistributable per firmware license terms in `LICENSE.*` files)
- **Buildroot package:** `BR2_PACKAGE_LINUX_FIRMWARE`

## Required Firmware Blobs

### AMDGPU (GPU initialization)

The Radeon 780M (RDNA 3, Phoenix) integrated GPU requires the following firmware:

| Firmware file | Purpose |
|---|---|
| `amdgpu/gc_11_0_1_mes.bin` | MES (Micro-Engine Scheduler) firmware |
| `amdgpu/gc_11_0_1_mes1.bin` | MES pipe 1 |
| `amdgpu/gc_11_0_1_mes_2.bin` | MES alternative |
| `amdgpu/gc_11_0_1_pfp.bin` | PFP (Pre-Fetch Parser) |
| `amdgpu/gc_11_0_1_me.bin` | ME (Micro Engine) |
| `amdgpu/gc_11_0_1_rlc.bin` | RLC (Run List Controller) |
| `amdgpu/gc_11_0_1_imu.bin` | IMU (Internal Micro-controller Unit) |
| `amdgpu/psp_13_0_4_sos.bin` | PSP (Platform Security Processor) |
| `amdgpu/psp_13_0_4_ta.bin` | PSP Trusted Application |
| `amdgpu/psp_13_0_4_toc.bin` | PSP Table of Contents |
| `amdgpu/sdma_6_0_0.bin` | SDMA (System DMA) |
| `amdgpu/vcn_4_0_0.bin` | VCN (Video Codec Next) |
| `amdgpu/dcn_3_1_4_dmcub.bin` | DCN (Display Core Next) DMCUB |

**Buildroot config:** `BR2_PACKAGE_LINUX_FIRMWARE_AMDGPU=y`

### AMD CPU Microcode

Required for AMD Ryzen Z1 Extreme (Family 19h, Phoenix) microcode updates:

| Firmware file | Purpose |
|---|---|
| `amd-ucode/microcode_amd_fam19h.bin` | CPU microcode for Family 19h |

**Buildroot config:** `BR2_PACKAGE_LINUX_FIRMWARE_AMD_UCODE=y`

### Other Firmware (Future)

Firmware not yet required for Sprint 3 but likely needed later:

| Device | Firmware | Sprint needed |
|---|---|---|
| Wi-Fi (MediaTek MT7921) | `mediatek/WIFI_*` `mediatek/BT_*` | Sprint 5+ (networking) |
| Bluetooth | Same as Wi-Fi above | Sprint 5+ |
| SOF audio DSP | `amd/sof/` / `amd/sof-tplg/` | Sprint 4+ (native audio) |

## Reproducible Builds

For reproducible builds, the linux-firmware version must be pinned. Buildroot uses the version from its package definition, which is updated with Buildroot releases. After a Buildroot upgrade, run:

```sh
make ally-build
```

And verify that the firmware files listed above appear in the build output:

```sh
find output/ally/build/linux-firmware-* -name "*.bin" | sort
```

## Verification

After booting on the Ally, check dmesg for missing firmware:

```sh
dmesg | grep -i "firmware\|failed to load"
```

Expected output: no errors. If firmware is missing, the GPU will fail to initialize (no `/dev/dri/card*`), and the kernel will log messages like:

```
amdgpu: Direct firmware load for amdgpu/gc_11_0_1_mes.bin failed with error -2
```

The hardware verification tooling (`make hw-check`) will catch missing DRM nodes.
