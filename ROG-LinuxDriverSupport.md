# ROG Ally Linux Driver Support

Research on available Linux drivers and userspace tools for controlling
ASUS ROG Ally hardware (buttons, back paddles, gyro, TDP, fan curves, RGB).

## Kernel Drivers

### `asus-armoury` — Platform driver for ASUS Armoury hardware

- **Repo:** [uejji/asus-armoury](https://github.com/uejji/asus-armoury)
- **Stars:** ⭐8
- **Author:** Luke Jones ([flukejones](https://github.com/flukejones/))
- **Status:** Mainlined since **Linux 6.19**
- **Scope:** Low-level WMI/ACPI interface to ASUS hardware. Provides the
  sysfs attributes that userspace tools (asusctl, HHD, G-Helper Linux) consume
  for TDP control, fan curves, power profiles, and platform-specific features.
- **Build:** Standard kernel module with DKMS support (`make` / `make dkms`).

### `hid-asus-ally` — HID driver for ROG Ally handhelds

- **Repo:** [uejji/hid-asus-ally](https://github.com/uejji/hid-asus-ally)
- **Stars:** ⭐0
- **Author:** Luke Jones ([flukejones](https://github.com/flukejones/))
- **Scope:** HID (Human Interface Device) layer for ROG Ally controller
  inputs — gamepad buttons, sticks, gyroscope, and special buttons (ROG Crate,
  Command Center, back paddles).
- **Build:** Standard kernel module with DKMS support.

### `asus-wmi` — Mainline WMI driver

- **Repo:** [torvalds/linux: drivers/platform/x86/asus-wmi.c](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/asus-wmi.c)
- **Status:** Mainline, shipped with the kernel.
- **Scope:** General ASUS WMI platform driver. Handles keyboard backlight,
  battery charge limits, GPU mode switching (MUX), and fan profiles on many
  ASUS laptops and handhelds. Used by HHD as its primary kernel interface.

## Userspace Tools

### HHD (Handheld Daemon) — Primary ROG Ally solution

- **Repo:** [hhd-dev/hhd](https://github.com/hhd-dev/hhd)
- **Stars:** ⭐387 — **most active** handheld enablement project
- **Description:** Armoury Crate replacement for Linux. Acts as a vendor
  interface replacement for Windows handhelds running Linux.
- **ROG Ally features:**
  - **Back buttons (M1/M2 paddles)** — remappable
  - **ROG Crate button** — hold to switch right stick to mouse mode
  - **Side menu button** — double-tap for gamescope overlay
  - **Controller emulation** including gyroscope
  - **SteamOS shortcuts** (QAM, Xbox guide button)
  - **Fan curves** and **TDP controls**
  - **RGB remapping**
- **Supported ROG devices:** Ally, Ally X, Xbox Ally, Xbox Ally X, Z13 (2025)
- **Install:** `curl -L https://github.com/hhd-dev/hhd/raw/master/install.sh | bash`
- **Distro packages:** AUR (`hhd`, `adjustor`, `hhd-ui`), COPR (Fedora),
  Nix (`services.handheld-daemon`), pre-installed on Bazzite.

### asusctl — ASUS ROG daemon and CLI

- **Repo:** [OpenGamingCollective/asusctl](https://github.com/OpenGamingCollective/asusctl)
- **Stars:** ⭐467
- **Components:**
  - `asusd` — system-wide D-Bus daemon
  - `asusctl` — CLI client
  - `rog-control-center` — GUI application
- **Scope:** Laptop-focused; supports TDP via `asus-armoury` (Linux 6.19+).
  Handles AURA RGB, AniMe Matrix, fan curves, power profiles, GPU mode
  switching.
- **Install:** AUR (`asusctl`), Fedora (Terra repo), openSUSE, Nix, Solus.
- **Note:** Primarily targeted at ASUS laptops; ROG Ally support is secondary
  compared to HHD.

### G-Helper Linux — Lightweight ASUS control panel

- **Repo:** [utajum/g-helper-linux](https://github.com/utajum/g-helper-linux)
- **Stars:** ⭐359
- **Description:** Linux port of the Windows G-Helper. Covers ASUS ROG, TUF,
  Flow, Z13, Ally, Zenbook, Vivobook, and ProArt devices.
- **Features:** Performance modes (Silent/Balanced/Turbo), custom 8-point fan
  curves, battery charge limit, GPU mode switching (Eco/Standard/Optimized/
  Ultimate), CPU power limits (PL1/PL2), screen control (refresh rate, Panel OD,
  MiniLED), keyboard backlight + RGB, undervolting (AMD Curve Optimizer via
  `ryzen_smu`), CPU boost toggle, system tray.
- **Install:** `pip install g-helper-linux` or distro packages.
- **Requirements:** Kernel 6.2+ (6.9+ for all features), `asus-nb-wmi` module.

## Comparison Matrix

| Feature | HHD | asusctl | G-Helper Linux |
|---|---|---|---|
| Back button remapping | ✅ | ❌ | ❌ |
| Gyro support | ✅ | ❌ | ❌ |
| SteamOS shortcuts | ✅ | ❌ | ❌ |
| TDP / fan curves | ✅ | ✅ (6.19+) | ✅ |
| RGB control | ✅ | ✅ (AURA) | ✅ (AURA) |
| GPU mode switching | ❌ | ✅ | ✅ |
| Battery charge limit | ❌ | ✅ | ✅ |
| Undervolting | ❌ | ❌ | ✅ |
| Gamescope overlay | ✅ | ❌ | ❌ |
| Desktop GUI | ✅ (adjustor) | ✅ (rog-control-center) | ✅ (tray + Qt) |
| Targeted at handhelds | ✅ **primary** | ❌ (laptops) | ⚠️ secondary |

## Recommendation for PlayOS

For ROG Ally support in a Linux backend:

1. **Kernel layer:** Require `asus-armoury` (Linux 6.19+) and `hid-asus-ally`
   for full hardware access. These provide the sysfs and hidraw nodes that
   backends consume.

2. **Userspace integration:** HHD is the most complete solution for handheld-
   specific features (back buttons, gyro, gamepad emulation). It can run as a
   systemd user service and expose controller state via uhid/evdev, making it
   compatible with any engine.

3. **Alternative path:** Direct integration via `asus-armoury` sysfs +
   `hid-asus-ally` hidraw could be done in a dedicated PlayOS Linux backend
   under `src/backends/linux/`, avoiding the HHD dependency. This would give
   PlayOS full control over button mapping and device state.

4. **Bazzite reference:** Bazzite ships HHD pre-installed with all necessary
   kernel patches, making it the path of least resistance for a handheld-
   focused PlayOS distribution image.
