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

## WiFi

WiFi uses **iwd** + NetworkManager. iwd replaces the previously referenced
(but never installed) wpa_supplicant stack. The built-in MediaTek MT7922
adapter is supported through the `iwd` OpenRC service started in the
`playos-visual` runlevel, with NetworkManager configured via
`wifi.backend=iwd` and `wifi.iwd.autoconnect=yes`.

## Built-in controller

The ROG Ally controller exposes two input interfaces:
- **Xbox 360 pad** (`event9`, `js0`): vendor 045e product 028e version 0114.
  GLFW's gamepad mapping database includes a matching entry
  (`030000005e0400008e02000014010000`, "X360 Controller").
- **Asus Keyboard** (`event4`/`event5`/`event6`): vendor 0b05 product 1abe.
  Controller in desktop/HID mode sends keyboard scancodes.

The Shell uses the Raylib gamepad input backend which delegates to GLFW
joystick detection. GLFW on Wayland opens `/dev/input/event*` devices for
joystick polling; device grab behavior may interfere with the keyboard
fallback path used by the Asus Keyboard HID mode.

## External display

External displays are supported through the compositor output mirroring and
1080p lock:
- All outputs are mirrored at layout position (0,0) — no desktop-spanning.
- Displays reporting resolutions above 1920×1080 are forced to a custom
  1920×1080@60Hz mode via `wlr_output_state_set_custom_mode`.
- Some external displays (e.g., Dell U3219Q via DP-2 on amdgpu) do not flag a
  preferred mode. The compositor falls back to the first available mode from
  the mode list to establish the initial output configuration before applying
  the 1080p lock.

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
