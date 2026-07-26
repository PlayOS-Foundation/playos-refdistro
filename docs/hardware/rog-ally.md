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

The Shell uses the Raylib gamepad input backend (`playos-input-raylib`) which
delegates to GLFW joystick detection. GLFW on Wayland opens `/dev/input/event*`
devices for joystick polling; device grab behavior may interfere with the
keyboard fallback path used by the Asus Keyboard HID mode.

### USB bus sharing with WiFi

The Xbox controller (045e:028e) and the built-in MediaTek WiFi adapter
(0489:e0f5) **share USB Bus 1**:

```
Bus 001 Device 002: ID 045e:028e Microsoft Corporation Controller
Bus 001 Device 004: ID 0489:e0f5 MediaTek Inc. Wireless_Device
```

This means any USB bus-level event affecting the WiFi adapter (e.g., firmware
reset during `nmcli device wifi rescan`) may disrupt the Xbox controller on
the same bus. Observed symptoms:

- **xpad "magic message" failures**: `input input21: unable to receive magic
  message: -32` (EPIPE) — the xpad kernel driver fails to re-initialize the
  controller endpoint after a USB disruption.
- **Gamepad input loss after WiFi operations**: entering and leaving the WiFi
  screen (which triggers `nmcli device wifi rescan` via the async
  `Network::StartScan`) reproduces controller input failure. The gamepad fd
  remains open (GLFW keeps fd 15 → event9) and events flow from the evdev
  node, but GLFW may lose the gamepad mapping after a USB device remove/add
  cycle.
- **Persists across compositor restart**: restarting `playos-compositor` does
  not recover gamepad input, suggesting the issue is at the xpad driver or
  USB subsystem level, not the GLFW or Wayland layer.

### GLFW gamepad detection details

- GLFW 3.4.0 has the correct mapping built into the library binary:
  `030000005e0400008e02000014010000,X360 Controller,a:b0,b:b1,back:b6,dpdown:h0.4,`
  `dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b8,leftshoulder:b4,leftstick:b9,`
  `lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b10,`
  `righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b2,y:b3`
- No external `gamecontrollerdb.txt` is needed — the mapping is compiled in.
- `RaylibInputBackend::Down()` is called **15 times per frame** (once per
  `Button` enum value), each iterating all 4 gamepad slots × all GLFW
  buttons, producing ~960 GLFW API calls per frame for input polling alone.
  While this is inefficient, it is not the root cause of the failure.

### Driver investigation (in progress)

Potential solutions to the USB bus sharing conflict:

1. **ROG Ally-specific xpad driver patches** — upstream or ASUS-provided
   patches that harden the xpad driver against USB bus disruptions (e.g.,
   retry with backoff, recover endpoint state after EPIPE).
2. **Alternative WiFi backend** — switching from `nmcli`-based WiFi scanning
   to a direct iwd D-Bus API backend would eliminate `nmcli device wifi
   rescan` as a potential USB bus stressor.
3. **USB bus topology mitigation** — if the ROG Ally firmware allows
   re-routing the controller to a different USB bus or if a kernel quirk can
   isolate the devices, the bus-sharing conflict could be avoided entirely.
4. **GLFW joystick re-detection** — enhancing GLFW or the Shell to force
   joystick re-detection after USB device add/remove events (e.g.,
   `glfwSetJoystickCallback`) so that gamepad mapping is restored after a
   disconnect/reconnect cycle.

Verification commands for runtime diagnosis:
```bash
# Monitor USB events in real time during WiFi scan
udevadm monitor --udev --subsystem-match=input --subsystem-match=usb

# Check xpad driver state
cat /sys/module/xpad/parameters/*

# Verify GLFW mapping is present
strings /usr/lib/libglfw.so.3 | grep "030000005e0400008e02000014010000"
```

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
