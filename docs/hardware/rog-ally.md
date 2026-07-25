# ROG Ally

The ASUS ROG Ally is the primary PlayOS reference Runtime Device. These findings
are validation requirements for the Alpine implementation, not instructions to
copy historical Arch-specific workarounds.

## Hardware constraints

- The AMD Phoenix GPU requires its matching Alpine kernel module and firmware
  in both the image and early boot inputs.
- The kernel command line uses `amdgpu.sg_display=0` as a ROG Ally display
  workaround; it is harmless on other supported GPUs.
- USB Ethernet adapters using `r8152` can enumerate after early userspace
  starts. PXE and recovery workflows need bounded interface and link waits.

## Validation requirements

- Validate renderer, firmware, and kernel modules from the built image, not
  only from the build root.
- Confirm controller, Home, touch, and 60/120 Hz operation.
- Keep network-dependent work outside the first-frame path.
- Record the image digest and exact kernel, Mesa, firmware, and wlroots
  versions with each hardware result.
- Obtain firmware and modules through pinned Alpine packages; do not vendor
  blobs into this repository.

See [Validation](../validation.md) and
[Boot and services](../architecture/boot-and-services.md).
