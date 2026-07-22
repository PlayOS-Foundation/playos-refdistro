# PlayOS Installation — Post-Install Issues

Machine: **ASUS ROG Ally** (NVMe) — also tested on **ASUS UltraBook** (SATA)

Install-to-disk is functional: PXE boot → Shell UI → Install to Disk → reboot → boots from disk into PlayOS Shell.

---

## 1. ~~Installer runs in TTY/console~~ ✅ RESOLVED (2025-07-21)

**Resolution:** The installer now renders inside the PlayOS Shell as an inline screen with a progress bar. The old TTY/OpenRC approach is fully replaced.

- **`InstallerScreen`** — inline screen in `playos-shell/src/screens/installer_screen.cpp`. Uses gamepad/keyboard input via `PlayOS::Input::Pressed()`. Shows disk detection, confirmation with ERASE & INSTALL/CANCEL buttons, launches `/usr/bin/playos-installer`, polls `/run/playos/install-status` for real-time progress with animated bar, triggers reboot on completion.
- **`/usr/bin/playos-installer`** — standalone shell script at `playos-refdistro/alpine/install-script/playos-installer`. Writes progress stages to the status file. No OpenRC wrapper.
- **`playos-installer-gui`** — standalone raylib GUI at `playos-shell/src/installer/main.cpp`. Preserved for future compositor multi-client focus support (currently unused — spawned as a child process it can't receive keyboard focus from the compositor).
- Old `init.d/playos-installer` is superseded.

---

## 2. WiFi scanning and connection from Shell

**Current behavior:** ROG Ally has MediaTek MT7921 WiFi. Kernel modules load, rfkill unblocked. Shell WiFi screen exists with `PlayOS::Network::ScanNetworks()` / `Connect()` backend using `nmcli`. Packages needed: `networkmanager-wifi`, `networkmanager-cli`, `wpa_supplicant`.

**Fixes applied (2025-07-21):**
- Installer post-config installs WiFi packages + enables `wpa_supplicant` at boot
- `Connect()` in linux_network_backend.cpp falls back to `nmcli con add` for routers requiring explicit `key-mgmt`
- WiFi screen scrollable (auto-scrolls past visible rows)

✅ Confirmed working: scans 19 networks, connects to WPA2, gets DHCP IP.

---

## 3. Not all games/samples present after install

**Current behavior:** ~~The installer copies the `playos-samples` directory from the PXE image to `/usr/share/playos/` on the installed disk, but some samples may be missing.~~ 

**Fix (2025-07-22):** The Shell looks for samples at `/playos-samples/build/` relative to the shell binary. Fixed both install paths:
- **Disk-image path** (`build-disk-image.sh`): Samples now installed to `/playos-samples/build/` (was `/usr/share/playos/`).
- **Legacy installer** (`install-script/playos-installer`): Now copies `/playos-samples/build/*` from the live ISO instead of `/usr/share/playos/*`.
All PlayOS samples (hello-playos, space-invaders) should be available on the installed system. Needs on-device verification.

---

## 4. Analog stick not working in Space Invaders

**Current behavior:** The ROG Ally's built-in gamepad analog sticks are not recognized by Space Invaders on the disk-booted system. D-pad/buttons may or may not work. This may be a device profile issue — the compositor needs to map the ROG's input devices correctly.

**Desired behavior:** Both analog sticks and all buttons should work in Space Invaders and other games.

**Files involved:**
- `playos-runtime/` (compositor input handling)
- `playos-runtime-devices/` (device profiles/quirks)

---

## 5. ROG Ally Home button not recognized

**Current behavior:** The ROG Ally's dedicated Home button (and possibly other special buttons like Armory Crate) are not mapped/recognized by the compositor. This is likely a device-specific key mapping missing from the device profile.

**Desired behavior:** The Home button should be recognized and usable (e.g., to return to the Shell home screen).

**Files involved:**
- `playos-runtime/` (input/keyboard handling)
- `playos-runtime-devices/` (ROG Ally device profile)

---

## Additional issues found during audit (2025-07-21, ROG Ally disk boot)

### 6. nmcli / nmtui not installed
**Finding:** NetworkManager is installed and running, but `networkmanager-cli` (nmcli) and `networkmanager-tui` (nmtui) are NOT part of the ISO. Users cannot manage WiFi or network connections from the terminal.
**Fix (2025-07-22):** Added `networkmanager-cli networkmanager-tui networkmanager-wifi` to `mkimg.playos.sh` apks, `genapkovl-playos.sh` world file, and `build-disk-image.sh` package list.
**Files:** `playos-refdistro/alpine/genapkovl-playos.sh` (world file), `mkimg.playos.sh`, `scripts/build-disk-image.sh`

### 7. iwd not in any runlevel
**Finding:** `iwd` (Wireless daemon) is installed but not enabled in any OpenRC runlevel. wlan0 shows as "unmanaged" in NetworkManager until iwd is started. After starting iwd manually, wlan0 goes to UP state but no WiFi networks appear.
**Fix (2025-07-22):** Added `rc_add iwd default` to both `genapkovl-playos.sh` and `build-disk-image.sh`. iwd starts automatically on boot alongside wpa_supplicant and NetworkManager.
**Files:** `playos-refdistro/alpine/genapkovl-playos.sh` (rc_add iwd default), `scripts/build-disk-image.sh`

### 8. WiFi scanning returns no networks (possible firmware/driver issue)
**Finding:** After starting iwd + NetworkManager, `nmcli device wifi list` returns nothing. wlan0 is UP but has NO-CARRIER. This could be:
- Missing WiFi firmware for the ROG's MediaTek/AMD WiFi chip
- rfkill (all rfkill switches show state=1/unblocked, so not blocked)
**Fix (2025-07-22):** Added `linux-firmware-mediatek` to `mkimg.playos.sh`, `genapkovl-playos.sh` world file, and `build-disk-image.sh` package list. MT7921 firmware should now be available. Still needs on-device verification on ROG Ally.
**Files:** `mkimg.playos.sh` (firmware packages), world file, `scripts/build-disk-image.sh`

### 9. No timezone set
**Finding:** `/etc/localtime` is not set (defaults to UTC). The system clock may be off.
**Fix (2025-07-22):** UTC symlink created during disk image build (`build-disk-image.sh`). `playos-firstboot` service also ensures `/etc/localtime` → UTC is present on first boot if not already configured. The Shell UI should eventually offer user-configurable timezone selection; UTC is the safe appliance default.

### 10. Input device mapping gaps
**Finding:** ROG Ally has multiple input devices:
- Microsoft X-Box 360 pad (built-in controller — works partially)
- Asus N-KEY Device (keyboard + Consumer Control — includes Home/Armory Crate buttons)
- NVTK0603 Touchscreen
- Asus WMI hotkeys
Analogue sticks and Home button are not recognized by games. The compositor likely needs a ROG-specific device profile to map all these correctly.
**Files:** `playos-runtime/` (compositor input), `playos-runtime-devices/` (device profiles)

### 11. GRUB boot order prefers PXE over disk
**Finding:** `efibootmgr` shows boot order places PXE (0005) before Alpine disk (0006). System tries network boot first on every startup. Also, stale EFI entries from previous distros (Fedora, SteamOS, Pop!_OS, Limine) remain in NVRAM.
**Fix (2025-07-22):** Post-install EFI cleanup now matches `PXE|Network` entries in addition to distro entries. Both the old installer script and the new `playos-firstboot` service (disk-image path) clean these. `efibootmgr -o` sets PlayOS as exclusive boot priority.
**Files:** `playos-refdistro/alpine/install-script/playos-installer` (post-install EFI cleanup), `alpine/init.d/playos-firstboot`, `genapkovl-playos.sh` (world)

---

## Recommended approach

1. Fix all issues on the **running installed PlayOS on the ROG** (disk boot) to avoid PXE rebuild cycles.
2. Once verified working, update the source repos:
   - `playos-runtime` / `playos-runtime-devices` for input/device issues
   - `playos-shell` for installer GUI (`src/installer/main.cpp`) + WiFi UI
   - `playos-refdistro` for installer backend (`alpine/install-script/playos-installer`) + ISO build
   - `playos-samples` for missing games
3. Rebuild ISO and re-verify on both ROG Ally and UltraBook.
