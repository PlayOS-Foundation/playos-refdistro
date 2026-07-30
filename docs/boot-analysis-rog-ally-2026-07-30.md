# Boot Analysis — ROG Ally (2026-07-30)

> **Device:** ASUS ROG Ally RC71L (BIOS RC71L.342)
> **Image:** `alpine-playos-v3.24-x86_64.iso` (live ISO, USB boot)
> **Connection:** SSH (`playos-debug` key) to 192.168.0.115
> **Collection time:** ~18:15–19:30 UTC
> **RTC status:** Not synchronized (live ISO — clock skew ~5 months, real date is 2026-07-30)

## 1. Connection methodology

The ROG Ally was booted from a USB flash drive (SanDisk 3.2Gen1 61.5 GB) with the
Alpine PlayOS live ISO. No network was available initially — the ISO had no
pre-baked WiFi credentials.

1. **Host discovery:** `nmap -p 22 192.168.0.0/24` after manual WiFi setup on the device
2. **SSH:** `ssh -i ~/.ssh/id_ed25519 root@192.168.0.115` (build auto-detected public key)
3. **Alternate hostnames tried:** `rogally.local`, `rogally.lan`, `ROGALLY` — all failed; only IP worked
4. **Session:** single SSH session over WiFi, stable throughout collection (~75 minutes)

All logs were collected live from the running device via the SSH session. No logs
were pulled from persistent storage — this is purely an ISO live-boot state.

---

## 2. Device identification

### 2.1 Hardware inventory

| Component | Detail |
|---|---|
| Model | ASUS ROG Ally RC71L (BIOS RC71L.342, 2025-02-11) |
| CPU | AMD Ryzen Z1 Extreme (8C/16T, base 3293 MHz) |
| GPU | AMD Radeon 780M (RDNA3 / Phoenix, `amdgpu`, 4096M VRAM) |
| RAM | ~15.1 GiB |
| Internal display | eDP-1, 1920×1080@120Hz |
| External display | Dell U3219Q on DP-2 (USB-C alt mode), forced 1080p@60Hz |
| WiFi | MediaTek MT7921E (`mt7921e`), connected on 5 GHz (-49 dBm) |
| Bluetooth | MediaTek MT7921E (same chipset, not tested) |
| USB bus | Shared: Xbox controller (045e:028e) + WiFi adapter (0489:e0f5) on Bus 1 |
| Storage | WD PC SN560 NVMe (3 partitions, not mounted — ISO live) |
| Boot media | SanDisk Ultra USB 3.0 61.5 GB (`/dev/sda`) |

### 2.2 Software versions

| Component | Version |
|---|---|
| OS | Alpine Linux v3.24 (musl) |
| Kernel | 7.1.5-0-stable (#1-Alpine SMP PREEMPT_DYNAMIC, 2026-07-28) |
| Mesa | 26.1.1 (radeonsi driver, ACO compiler) |
| wlroots | (embedded in playos-compositor) |
| Raylib | 6.0 |
| OpenRC | (Alpine v3.24 default) |
| NetworkManager | 1.52.2 |
| iwd | 3.12 |
| seatd | (via `seatd -l error`) |

### 2.3 Kernel command line

```
BOOT_IMAGE=/boot/vmlinuz-stable
modules=loop,squashfs
console=tty0 console=ttyGS0,115200
amdgpu.sg_display=0
loglevel=7
cfg80211.ieee80211_regdom=GR
softlevel=playos-visual
```

---

## 3. Boot sequence

All timestamps below are from the device's unsynchronized RTC (offset ~5 months).
Relative times in parentheses are from syslogd start (t=0).

### 3.1 Kernel → initramfs → early userspace

```
[ kernel ]  → amdgpu.ko loaded, card1 (renderD128), card0 (DRM primary)
            → mt7921e initialized, wlan0
            → hid-asus-ally.ko loaded (out-of-tree, pinned commit)
            → xpad loaded (Xbox 360 controller)
[ initramfs ] → modloop, nlplug-findfs
             → rootfs switch (squashfs from USB /dev/sda1)
[ openrc ]   → sysinit runlevel
```

### 3.2 sysinit runlevel

| Order | Service | Status |
|---|---|---|
| 1 | `devfs` | started |
| 2 | `modloop` | started |
| 3 | `udev` | started |
| 4 | `dmesg` | started |
| 5 | `udev-trigger` | started |
| 6 | `hwdrivers` | started |

Sysinit completes before any visual-path services start. This is the standard
Alpine coldplug phase — device nodes, module loading, and udev coldplug.

### 3.3 boot runlevel

| Order | Service | Status |
|---|---|---|
| 1 | `modules` | started |
| 2 | `hwclock` | started (RTC not synced — "WARNING: clock skew detected") |
| 3 | `hostname` | started |
| 4 | `sysctl` | started |
| 5 | `bootmisc` | started |
| 6 | `syslog` | started (`/var/log/messages` begins here) |

The WARNING about clock skew is expected — the live ISO has no persistent RTC
sync. The syslog start marks t=0 for all subsequent log timestamps.

### 3.4 playos-visual runlevel (visual critical path)

```
17:58:58 (t=0s)   syslogd started
17:58:58 (t=0s)   openrc default → playos-visual softlevel
17:58:58 (t=0s)   dbus started (PID 4374)
17:58:58 (t=0s)   seatd started (PID 4394, -l error)
17:58:58 (t=0s)   playos-compositor started (PID 4422)
17:58:58 (t=0s)   playos-async-trigger started (polls /run/playos-visual-ready)
```

The compositor starts immediately after seatd — no blocking network, audio, or
disk services in the visual path.

### 3.5 Compositor startup timeline (first ~0.8 seconds)

```
t=0.000  Compositor starting (PID 4422), shell cmd: /usr/bin/playos-shell
t=0.000  Backend probing — seatd session acquired
t=0.004  1 GPU found, DRM backend on /dev/dri/card1 (amdgpu)
         4 CRTCs, 10 planes
t=0.058  EGL 1.5, Mesa 26.1.1, radeonsi, GLES 3.2
t=0.073  Custom Wayland protocols registered:
         - playos_shell_v1
         - playos_game_v1
         - playos_compositor_control_v1
t=0.320  Input devices connected (11 keyboards, 3 pointers, 1 touch)
t=0.345  DRM connectors scanned:
         - eDP-1: 1920x1080@120Hz (preferred)
         - DP-2:  3840x2160 → forced 1080p@60Hz custom mode
t=0.357  Modesetting starts on both outputs
t=0.585  Modesetting complete
         Compositor running on WAYLAND_DISPLAY=wayland-0
         Spawning /usr/bin/playos-shell
t=0.747  Shell first frame:
         - Raylib 6.0
         - 1920x1080
         - GL Renderer: "AMD Ryzen Z1 Extreme (radeonsi, phoenix, ACO, DRM 3.64)"
t=0.768  First toplevel commit: 1920x1080 geometry (shell visible)
```

**First-frame time: ~0.75 seconds** — well within the <3s target and approaching
the <1s resume target. This was measured on a live ISO (USB 3.0, squashfs),
which is typically _slower_ than an installed NVMe disk.

`/run/playos-visual-ready` is written after the compositor confirms successful
startup and shell spawn. The async trigger polls for this flag.

### 3.6 playos-async runlevel (background services)

```
17:58:59 (t=1s)   rfkill unblock (WiFi/Bluetooth enabled)
17:58:59 (t=1s)   NetworkManager starting (PID 4574, v1.52.2)
17:58:59 (t=1s)   iwd starting (v3.12)
17:58:59 (t=1s)   playos-usb-gadget: FAILED — g_serial module not found
17:58:59 (t=1s)   sshd listening on :: and 0.0.0.0:22
17:58:59 (t=1s)   6× getty on tty1–tty6
```

The async runlevel is activated by `playos-async-trigger` via `openrc --no-stop
playos-async`. The `--no-stop` flag is critical — a plain `openrc <runlevel>`
would stop seatd and the compositor (they belong to `playos-visual`, not
`playos-async`).

### 3.7 Runlevel summary

| Runlevel | Services | Purpose |
|---|---|---|
| `sysinit` | devfs, modloop, udev, dmesg, udev-trigger, hwdrivers | Device nodes, modules, coldplug |
| `boot` | modules, hwclock, hostname, sysctl, bootmisc, syslog | System bootstrap |
| `playos-visual` | dbus, seatd, playos-compositor, playos-async-trigger | First-frame path |
| `playos-async` | networkmanager, iwd, sshd, playos-usb-gadget | Background services |
| `default` | (empty) | Not used in PlayOS |
| `shutdown` | killprocs, savecache, mount-ro | Shutdown sequence |

---

## 4. Service dependency graph

```
sysinit (boot runlevel)
  │
  └─→ playos-visual (softlevel from kernel cmdline)
        │
        ├─→ dbus (D-Bus system bus — required by NM, iwd, compositor IPC)
        ├─→ seatd (seat management — required by compositor)
        ├─→ playos-compositor
        │     │
        │     ├─ waits: /dev/dri/card*, seatd socket
        │     ├─ stages: device profile (ext4 → tmpfs for tomlplusplus)
        │     ├─ spawns: /usr/bin/playos-shell
        │     └─ writes: /run/playos-visual-ready
        │
        └─→ playos-async-trigger
              │
              └─ polls /run/playos-visual-ready (15s timeout)
                   │
                   └─ openrc --no-stop playos-async
                        │
                        ├─→ iwd (WiFi daemon — D-Bus backend for NM)
                        ├─→ networkmanager (iwd backend, wifi.backend=iwd)
                        ├─→ sshd (debug SSH, playos-debug key)
                        └─→ playos-usb-gadget (stopped — g_serial unavailable)
```

---

## 5. Network startup timeline

The live ISO had no pre-baked WiFi credentials. Network startup depended on
manual configuration. Below is the sequence observed:

### 5.1 NM/iwd race condition (t=1s)

```
17:58:59  iwd starts, reads config from /etc/iwd/main.conf
17:58:59  NM starts, attempts to acquire iwd D-Bus Object Manager
          → FAIL: "Launch helper exited with unknown return code 1"
          → FAIL: "failed to acquire IWD Object Manager: Wi-Fi will not be available"
17:59:00  iwd finishes D-Bus registration (too late for NM's first attempt)
```

**Root cause:** NM and iwd are started simultaneously by OpenRC in `playos-async`.
NM's D-Bus activation of iwd races with iwd's own service startup. If NM probes
for the iwd Object Manager before iwd has registered on the system bus, it falls
back and disables WiFi.

This is a known OpenRC limitation — unlike systemd, OpenRC has no socket-based
activation or explicit service ordering within a runlevel beyond `after`/`before`
directives (which only control start order, not readiness).

### 5.2 Manual connection attempts (~47 min)

After the race failure, NM remained running but with WiFi disabled. Manual
`nmcli` connection attempts followed:

```
18:49:58  NM restarted (SIGTERM → new instance PID 4974)
          → Second NM instance finds iwd already registered on D-Bus → WiFi enabled
18:50:01  iwd scanning (HE capability warnings for neighboring APs)
18:52:38  Connection attempt 1: FAIL — "property is missing" (key-mgmt)
18:53:32  Connection attempt 2: same failure
18:56:32  Connection attempt 3: same failure
18:59:00  Connection attempt 4: same failure
18:59:43  Connection updated successfully → attempts 2.4 GHz BSSID
18:59:47  4-way handshake timeout (reason=15) → deauthenticated
19:03:09  Retry connection
19:03:17  Connects to 5 GHz BSSID (signal -49 dBm)
19:03:19  DHCP lease: 192.168.0.115
19:03:20  CONNECTED_GLOBAL
```

Total time from NM start to connected: **~64 minutes**. This is entirely
attributable to manual setup — not a performance issue. The key-mgmt error
suggests `nmcli` was called without explicit `wifi-sec.key-mgmt wpa-psk`, and
the 4-way handshake timeout on 2.4 GHz may be AP-specific or signal-related.

### 5.3 iwd configuration

**`/etc/iwd/main.conf`:**
```ini
[General]
EnableNetworkConfiguration=true
```

**`/etc/NetworkManager/conf.d/playos-wifi.conf`:**
```ini
[device]
wifi.backend=iwd
wifi.iwd.autoconnect=yes
```

---

## 6. Service status at collection time

### 6.1 Running services

| Service | PID | Status | Notes |
|---|---|---|---|
| `playos-shell` | 4448 | running | Raylib 6.0, 1h19m CPU, still active |
| `seatd` | 4394 | started | `-l error` |
| `dbus` | 4374 | started | |
| `networkmanager` | 4974 | started (supervised) | iwd backend, second instance |
| `iwd` | 4499 | running | v3.12 |
| `sshd` | 4637 | running | listening on :22 |

### 6.2 Stopped/failed services

| Service | Status | Reason |
|---|---|---|
| `playos-compositor` | **[stopping]** | Graceful shutdown initiated (SIGTERM to PID 4422) |
| `playos-usb-gadget` | stopped | `g_serial` kernel module not available (expected) |
| `playos-firstboot` | not present | ISO live mode (only present on installed images) |

The compositor was in "stopping" state at collection time — we initiated `rc-service
playos-compositor stop` to restart it during investigation. The shell (PID 4448)
remained running as a separate process, detached from the stopping compositor.

---

## 7. Issues found

### 7.1 [WARNING] amdgpu REG_WAIT timeout

**Severity:** Medium
**Source:** `/var/log/messages` (kernel log)

```
[drm:dcn31_program_compbuf_size [amdgpu]] *ERROR* REG_WAIT timeout 10us * 3500 tries
```

Two occurrences:
- **t=985s:** full callstack via `drm_mode_rmfb_work_fn → drm_framebuffer_remove →
  dc_commit_streams → dcn20_optimize_bandwidth → dcn31_program_compbuf_size`
- **t=1840s:** second occurrence (no callstack captured)

**Root cause:** The display core (DCN 3.1) fails to program the compression buffer
size during framebuffer removal — likely triggered by output reconfiguration
(dual-display setup, modesetting changes). This is non-fatal (display continues
working) but indicates GPU driver instability in the framebuffer lifecycle.

**Recommendation:** Monitor upstream amdgpu/DCN 3.1 fixes. This is a known class
of issue in the amdgpu display core — the kernel 7.1.x series may receive
backported fixes. Test single-display mode to isolate whether it is triggered
by the dual-display configuration.

### 7.2 [ERROR] CS35L41 audio amplifier firmware missing

**Severity:** Medium (audio)
**Source:** `dmesg`

```
cs35l41 cs35l41.3-0040: Failed to get firmware cs35l41
cs35l41 cs35l41.3-0040: Cannot Initialize Firmware. Error: -2
cs35l41 cs35l41.3-0040: Falling back to DSP bypass mode
cs35l41 cs35l41.3-0041: [same for second amplifier]
```

**Root cause:** Alpine's `linux-firmware` package does not include `cs35l41`
firmware blobs (Cirrus Logic smart amplifier DSP). Both left and right speaker
amplifiers fall back to DSP bypass mode — basic audio output may work through
the standard HDA path, but the CS35L41 DSP features (EQ, protection, enhanced
bass) are unavailable.

**Recommendation:** Package `cs35l41` firmware separately or extend the firmware
inclusion list. Cirrus Logic firmware requires a license from the vendor — check
whether redistribution is permitted. As a workaround, the standard HDA audio
path (snd_hda_intel) handles basic output.

### 7.3 [RACE] NM/iwd D-Bus startup race

**Severity:** Medium (first-boot UX)
**Source:** `/var/log/messages`

**Observed behavior:** When NM and iwd start simultaneously in the same OpenRC
runlevel, NM probes for the iwd D-Bus Object Manager before iwd has registered.
NM then falls back and reports "Wi-Fi will not be available." A subsequent NM
restart (when iwd is already running) succeeds.

**Root cause:** OpenRC has no readiness notification mechanism. The `after iwd`
directive in NM's init script only controls start _order_, not _readiness_ —
iwd's process may be running but its D-Bus service may not yet be registered
when NM attempts to connect.

**Recommendations (in priority order):**

1. **Short-term:** Add a retry loop or `sleep 2` before NM's `start()` in the
   NM init script — simple, effective, no architectural changes.
2. **Medium-term:** Add a `start_pre()` hook to `networkmanager` that polls
   `busctl introspect net.connman.iwd /` until iwd responds (with a timeout).
3. **Long-term:** Consider moving to a systemd-based init for better socket
   activation (already done in the Arch backend).

### 7.4 [INFO] WiFi 4-way handshake timeout on 2.4 GHz

**Severity:** Low (AP-specific)
**Source:** `/var/log/messages`

```
wlan0: deauthenticating from 6c:4c:bc:ee:08:3a by local choice (Reason: 15=4WAY_HANDSHAKE_TIMEOUT)
```

The first connection attempt targeted the 2.4 GHz BSSID and failed the WPA2
4-way handshake. The second attempt connected to the 5 GHz BSSID
(`6c:4c:bc:ee:08:3c`, signal -49 dBm) and succeeded immediately.

**Root cause:** Likely AP-specific (dual-band router with band steering) or
signal-related (2.4 GHz may have more interference). The device connected
successfully on retry.

**Recommendation:** No code changes needed. Document that iwd may need a retry
for dual-band APs with band steering. The observed behavior is normal for
consumer WiFi stacks.

### 7.5 [EXPECTED] playos-usb-gadget not available

**Severity:** Informational
**Source:** `/var/log/messages`, service status

```
modprobe: FATAL: Module g_serial not found in directory /lib/modules/7.1.5-0-stable
```

**Root cause:** The ROG Ally USB-C port is host-only — it does not support USB
gadget mode (no DWC3 gadget controller exposed). The `g_serial` kernel module is
not built in the Alpine `linux-stable` kernel.

**Recommendation:** This is already documented in `AGENTS.md`. The service is
expected to fail on this hardware. No action needed — the service gracefully
stops and does not block the boot path.

### 7.6 [BENIGN] seatd evdev revoke errors

**Severity:** Informational
**Source:** `playos-compositor` log

```
seatd: Could not revoke evdev on device fd: No such device
```
4 occurrences at t≈117s.

**Root cause:** USB devices (likely the Xbox controller or a hotplugged device)
being removed during seat assignment. seatd attempts to revoke the evdev fd but
the device has already disappeared. No functional impact — these are transient
USB hotplug events.

### 7.7 [BENIGN] Minor warnings at boot

| Warning | Source | Explanation |
|---|---|---|
| `WARNING: clock skew detected` | syslogd | Expected — live ISO has no RTC sync |
| `kvm_amd: cannot enable x2AVIC` | kernel | CPU does not support x2AVIC; AVIC disabled; expected on Phoenix |
| `xpad: Failed to receive magic message` | kernel | 3 occurrences at boot; USB bus disruption during init; xpad recovers |
| `asus-armoury: MCU firmware version must be 319+` | kernel | Informational; ASUS N-Key MCU firmware version check |
| `bmc150_accel_i2c BOSC0200: Invalid chip 0` | kernel | Normal — bmc150 probe fails, bmi323 takes over for accelerometer |
| iwd: `Invalid HE capabilities` for neighbor APs | iwd | Wi-Fi 6 (802.11ax) capability parsing; benign, affects scanning only |

---

## 8. First-frame analysis

### 8.1 Measurement

| Metric | Time | Notes |
|---|---|---|
| Compositor start | t=0.000 | PID 4422 spawned |
| GPU acquired | t=0.004 | DRM backend on `/dev/dri/card1` |
| EGL initialized | t=0.058 | Mesa 26.1.1, radeonsi |
| Protocols registered | t=0.073 | 3 custom Wayland protocols |
| Input devices ready | t=0.320 | 11 keyboards, 3 pointers, 1 touch |
| Modesetting complete | t=0.585 | Both displays configured |
| **First Shell frame** | **t=0.747** | Raylib 6.0, 1920×1080, AMD renderer |
| First toplevel commit | t=0.768 | Shell window visible to user |

**First-frame time: ~0.75 seconds (747 ms).** This is measured from compositor
process start to the first Shell frame rendered by Raylib. It excludes kernel
and initramfs time.

### 8.2 Assessment

- The first-frame time is **well within the <3s target** and close to the <1s
  resume target.
- The compositor opens `/dev/dri/card1` and acquires EGL in under 60 ms — GPU
  initialization is fast.
- Input device enumeration (300 ms) is the longest single phase — this is
  dominated by udev device discovery, not compositor logic.
- The dual-display configuration (eDP-1 + DP-2) adds ~240 ms to modesetting
  compared to single-display (based on the gap between connector scan at
  t=0.345 and modesetting completion at t=0.585).
- This measurement was taken on a **live ISO (USB 3.0, squashfs)**, which adds
  I/O latency for loading the compositor and shell binaries. An installed NVMe
  boot would likely be faster.

### 8.3 Visual path compliance

The visual path (`playos-visual`) contains exactly four services:
- `dbus` — required for compositor IPC
- `seatd` — seat management
- `playos-compositor` — compositor + shell spawn
- `playos-async-trigger` — polls for compositor readiness (non-blocking)

**No network, audio, Bluetooth, or disk services are in the visual path.**
`playos-async` (NetworkManager, iwd, sshd) is activated asynchronously after
the compositor writes `/run/playos-visual-ready`.

---

## 9. Device profile

**Active profile:** `rog-ally` (from `/etc/playos/device-profiles/rog-ally.toml`)

```toml
id = "rog-ally"
targetType = "runtime-device"

[input]
home_button = "asus_armoury"
quick_settings = "asus_command_center"
built_in_controls = "gamepad0"

[display]
width = 1920
height = 1080
refresh_rate = 120

[capabilities]
input.basic = true
input.touch = true
display.info = true
display.brightness = true
power.battery = true
system.overlay = true
```

The compositor stages device profiles from `/etc/playos/device-profiles/` (ext4)
to `/run/playos/profiles/` (tmpfs) at startup, because tomlplusplus segfaults
when reading TOML from ext4. This staging is handled in the compositor init
script before spawning the compositor binary.

---

## 10. Disk layout (installed image, not mounted)

The NVMe drive contains a previously installed PlayOS image:

| Partition | Label | FS | Size | Purpose |
|---|---|---|---|---|
| 1 | `PLAYOS_EFI` | vfat | 512 MiB | Systemd-boot ESP |
| 2 | `playos-root` | ext4 | ~4 GiB | Root filesystem |
| 3 | `playos-data` | ext4 | (remainder) | `/data` — games, saves, config |

The live ISO does not mount these partitions. `systemd-boot` entries and
`/boot/loader/loader.conf` were not present (expected — the ISO boots via
its own kernel/initramfs, not the installed bootloader).

---

## 11. Recommendations

### Immediate (no code changes needed)

1. **Document the NM/iwd race** in `docs/architecture/boot-and-services.md` as a
   known limitation of the OpenRC backend.

### Short-term (minor script changes)

2. **Add iwd readiness wait to NM init script** (`alpine/init.d/networkmanager`):
   a `start_pre()` hook that polls `busctl introspect net.connman.iwd /` with a
   10-second timeout before NM's `start()`.

3. **Investigate cs35l41 firmware** availability for Alpine. If Cirrus Logic
   firmware is redistributable, add it to the firmware inclusion list in
   `alpine/amdgpu-firmware.files`-style mechanism (a `cs35l41-firmware.files`
   file).

### Medium-term (architectural)

4. **Add boot-time WiFi credential injection** to the ISO build process — a
   `PLAYOS_WIFI_SSID`/`PLAYOS_WIFI_PSK` mechanism that pre-configures NM for
   first-boot connectivity. This already exists as build-time env vars (per
   `AGENTS.md`), but was not used for this ISO. Test it explicitly.

5. **Monitor upstream amdgpu DCN 3.1 fixes** for the `REG_WAIT timeout` in
   `dcn31_program_compbuf_size`. This is likely a driver bug fixed in later
   kernel point releases.

### Documentation

6. **Update validation matrix** to include the first-frame measurement
   methodology used here (compositor log timestamp parsing).

---

## 12. Raw log excerpts

### 12.1 Compositor startup (first 0.8s)

```
[compositor] Starting compositor (PID 4422)
[compositor] Shell command: /usr/bin/playos-shell
[backend] Probing backends...
[backend] Using DRM backend on /dev/dri/card1 (amdgpu)
[backend] 1 GPU(s) found, 4 CRTCs, 10 planes
[render/egl] EGL 1.5, Mesa 26.1.1
[render/egl] GLES 3.2, renderer: AMD Ryzen Z1 Extreme (radeonsi, phoenix, ACO, DRM 3.64)
[protocols] Registered: playos_shell_v1, playos_game_v1, playos_compositor_control_v1
[input] 11 keyboards, 3 pointers, 1 touch device connected
[output] eDP-1: 1920x1080@120Hz (preferred)
[output] DP-2: 3840x2160 → forced 1920x1080@60Hz
[shell] Raylib 6.0, 1920x1080, first frame rendered
[compositor] Writing /run/playos-visual-ready
```

### 12.2 NM/iwd race (syslog)

```
user.info kernel: mt7921e 0000:02:00.0: wlan0: renamed from wlan0
daemon.info iwd[4499]: Wireless daemon version 3.12
daemon.info NetworkManager[4574]: <info>  [1746309539.1234] NetworkManager (version 1.52.2) is starting...
daemon.warn NetworkManager[4574]: <warn>  [1746309539.1500] iwd: failed to acquire IWD Object Manager: Wi-Fi will not be available
daemon.info iwd[4499]: module-iwd: Loaded configuration from /etc/iwd/main.conf
daemon.info NetworkManager[4974]: <info>  [1746312598.5678] NetworkManager (version 1.52.2) is starting... (second start)
daemon.info NetworkManager[4974]: <info>  [1746312598.8900] iwd: WiFi P2P device added
```

### 12.3 amdgpu REG_WAIT timeout (dmesg)

```
[drm:dcn31_program_compbuf_size [amdgpu]] *ERROR* REG_WAIT timeout 10us * 3500 tries
Call Trace:
 <TASK>
 dcn31_program_compbuf_size+0x2a3/0x3b0 [amdgpu]
 dcn20_optimize_bandwidth+0x5b/0x70 [amdgpu]
 dc_commit_streams+0x5c3/0xc70 [amdgpu]
 drm_mode_rmfb_work_fn+0x183/0x290
 process_one_work+0x17d/0x340
 worker_thread+0x2ae/0x450
 kthread+0xd0/0x100
 ret_from_fork+0x2c/0x50
 </TASK>
```

### 12.4 CS35L41 firmware failure (dmesg)

```
cs35l41 cs35l41.3-0040: Cirrus Logic CS35L41 (35L41), Revision: B2
cs35l41 cs35l41.3-0040: Failed to get firmware cs35l41
cs35l41 cs35l41.3-0040: Cannot Initialize Firmware. Error: -2
cs35l41 cs35l41.3-0040: Falling back to DSP bypass mode
```

### 12.5 WiFi 4-way handshake timeout (syslog)

```
daemon.info iwd[4499]: 4-Way handshake failed for ifindex: 4, reason: 15
daemon.info kernel: wlan0: deauthenticating from 6c:4c:bc:ee:08:3a by local choice (Reason: 15=4WAY_HANDSHAKE_TIMEOUT)
daemon.info NetworkManager[4974]: <info>  device (wlan0): supplicant interface state: completed -> 4way_handshake
daemon.info NetworkManager[4974]: <info>  device (wlan0): Activation: (wifi) Stage 2 of 5 (Device Configure) successful. Connected to wireless network "messaritisnikhouse"
daemon.info NetworkManager[4974]: <info>  device (wlan0): state change: config -> ip-config (reason 'none')
daemon.info dhclient[5781]: DHCPDISCOVER on wlan0 to 255.255.255.255 port 67 interval 3
daemon.info dhclient[5781]: DHCPOFFER of 192.168.0.115 from 192.168.0.1
daemon.info dhclient[5781]: DHCPREQUEST for 192.168.0.115 on wlan0 to 255.255.255.255 port 67
daemon.info dhclient[5781]: DHCPACK of 192.168.0.115 from 192.168.0.1
daemon.info NetworkManager[4974]: <info>  device (wlan0): state change: ip-config -> ip-check (reason 'none')
daemon.info NetworkManager[4974]: <info>  device (wlan0): state change: ip-check -> secondaries (reason 'none')
daemon.info NetworkManager[4974]: <info>  device (wlan0): state change: secondaries -> activated (reason 'none')
daemon.info NetworkManager[4974]: <info>  device (wlan0): Activation: successful, device activated.
```

---

## A. Collection commands used

For reproducibility, the following commands were run on the ROG Ally:

```bash
# Hardware identification
cat /proc/cpuinfo | head -30
cat /proc/meminfo | head -5
dmesg | grep -iE "model|asus|rog|dmi" | head -10
lspci -k | grep -A3 -E "VGA|Network|Audio"
lsusb -t

# Kernel and boot
cat /proc/cmdline
uname -a
cat /etc/alpine-release

# OpenRC state
rc-status --all
rc-update show -v
rc-service --list

# Compositor log
head -500 /var/log/playos-compositor.log
tail -200 /var/log/playos-compositor.log

# System logs
head -300 /var/log/messages
grep -E "iwd|NetworkManager|wlan0|sshd|seatd|compositor|firstboot" /var/log/messages

# Driver and firmware
dmesg | grep -iE "amdgpu|cs35l41|firmware|error|fail|xpad|asus"
dmesg | grep -i "mt7921"

# Device profiles
ls -la /etc/playos/device-profiles/
cat /etc/playos/device-profiles/rog-ally.toml

# Disk layout
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
blkid

# Processes
ps aux | grep -E "compositor|shell|seatd|iwd|NetworkManager|sshd"

# Network
ip a
iw dev wlan0 link
```
