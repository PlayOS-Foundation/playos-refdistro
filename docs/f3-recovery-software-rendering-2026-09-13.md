# F3 — recovery renders without accelerated graphics — 2026-09-13

Sprint 14 T6 required: *"Recovery must work without AMDGPU, using SimpleDRM or
software rendering"*, and MVP criterion 19: *"Recovery usable without
accelerated graphics"*. This closes that gap.

## What was actually wrong

Three separate things, none of them cosmetic:

1. **The "SimplEDRM fallback" never existed.** `playos_compositor_start()`'s
   fallback set `WLR_BACKENDS=headless` — a compositor with no output at all, so
   a machine whose graphics had failed showed nothing.
2. **The kernel could not provide a fallback display.** The Ally config had
   `CONFIG_DRM_SIMPLEDRM` deliberately disabled (an earlier attempt appeared to
   fight AMDGPU for DRM master) and `CONFIG_FB`/`CONFIG_SYSFB_SIMPLEFB` off, so
   there was no firmware-framebuffer DRM device to fall back to.
3. **`playos.recovery` on the kernel cmdline was a no-op.** The check ran before
   `playos_mount_virtual()`, so `/proc/cmdline` did not exist yet and
   `playos_cmdline_has_flag()` always returned 0. (The Volume-Down button entry
   uses evdev, which is why recovery *did* work on the device.)

## Changes

| Area | Change |
|---|---|
| `board/ally/linux.config`, `board/qemu-x86_64/linux.config` | `FB=y`, `SYSFB=y`, `SYSFB_SIMPLEFB=y`, `DRM_SIMPLEDRM=y`. SimplEDRM gives userspace a KMS device over the firmware framebuffer; AMDGPU is built-in and probes first, and the DRM aperture helpers evict SimplEDRM when it does, so an accelerated machine keeps master and SimplEDRM simply disappears. |
| `playos-compositor` `drm_backend.c` | If the accelerated renderer cannot be created, retry with `WLR_RENDERER=pixman` before giving up (safe there: the renderer has not been published to the display yet). |
| `playos-compositor` `compositor.c` | `PLAYOS_RENDERER` forces the renderer (recovery sets `pixman`); a **pre-flight card probe** picks the device before anything is created — discovered GPU first, otherwise any `/dev/dri/card*` with a usable output (that is SimplEDRM when the GPU driver never probed) — then creates the backend exactly once. The headless path now also creates a renderer + allocator (`wlr_output_init_render()` asserts on NULL and aborts). |
| `playos-init` `supervisor.c` | When recovery is entered, the compositor is spawned with `PLAYOS_RENDERER=pixman`; if the compositor is *down* (the realistic "graphics is what broke" case) the recovery UI entry starts it in software mode and then the shell. |
| `playos-init` `main.c` | Kernel-cmdline decisions moved after `playos_mount_virtual()`, and the cmdline is logged at boot. |

## Verification — `scripts/qemu-recovery-check.sh`

The QEMU kernel has `DRM_VIRTIO_GPU`, `DRM_BOCHS` and `DRM_SIMPLEDRM` but no
cirrus driver, so booting with QEMU's **cirrus VGA** means the only DRM device in
the guest is SimplEDRM over the OVMF framebuffer — no amdgpu, no EGL/GL, no GBM.
The check asks for the recovery UI on the cmdline (`playos.recovery`), waits for
the shell, then reads the emulated framebuffer through the QEMU monitor:

```
framebuffer      : 800x600
non-black pixels : 480000/480000 (100.00%)
distinct colours : 38
PASS: recovery UI rendered with software rendering (no GPU driver)

renderer/device:
   playos-compositor: renderer forced to 'pixman'
init:
   [init] cmdline: console=ttyS0,115200n8 quiet playos.recovery initrd=initrd
   [init] recovery requested via cmdline (playos.recovery)
```

The captured frame (`docs/evidence/f3-recovery-menu-no-gpu-2026-09-13.png`) is
the recovery menu — title **RECOVERY MODE**, items REBOOT / SHUTDOWN / FACTORY
RESET / ROLLBACK / VIEW LOGS, hints `D-PAD: NAVIGATE  A: SELECT  B: BACK`, and
the PlayOS status bar — drawn on the navy PlayOS palette.

So: with no accelerated GPU driver at all, the compositor came up on SimplEDRM
with the pixman renderer, the shell ran, and the recovery menu reached the
screen.

## Notes and residual risk

- Enabling SimplEDRM on the Ally is the one change that touches the *normal*
  boot path. The handover is the arrangement mainstream distros ship; the
  compositor also prefers the real GPU explicitly. It still wants an on-device
  confirmation (boot normally, then boot holding Volume Down / with
  `playos.recovery`).
- Recovery rendering is software, so it is slow by design — fine for a menu.
- A machine with *no* DRM device at all (no firmware framebuffer either) still
  ends up headless; the next step there would be a kernel-console text menu.
