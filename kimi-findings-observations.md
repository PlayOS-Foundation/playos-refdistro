# Findings & Observations — Alpine ISO Build (LiveUSB + disk image)

> **Date:** 2026-07-29/30
> **Scope:** LiveUSB boot, WiFi bring-up, disk install boot, debugging infrastructure.
> **Method:** script review, ISO artifact inspection (`xorriso -osirrox`), QEMU
> harness (serial socket + screendump + SSH hostfwd), on-device testing (ROG Ally).

---

## 1. Bugs found and fixed (verified in built artifacts)

### 1.1 WiFi profile never reached the LiveUSB apkovl
- **Symptom:** LiveUSB never auto-connected to `messaritisnikhouse`; disk install did.
- **Root cause:** `scripts/build-iso-ubuntu.sh` Phase 1 (disk image) forwarded
  `PLAYOS_WIFI_SSID`/`PLAYOS_WIFI_PSK` into nspawn, but **Phase 3 (ISO build) did not**,
  so `alpine/genapkovl-playos.sh` silently skipped baking
  `01-wifi-auto.nmconnection`.
- **Fix:** added the two `--setenv` lines to Phase 3. Verified present in ISO.

### 1.2 Device profiles missing from the LiveUSB
- **Symptom:** compositor logged `Device profile not found: /etc/playos/device-profiles/rog-ally.toml`; compositor input backend + shell ran without device config.
- **Root cause:** `build-disk-image-alpine.sh` installed profiles only into `$MNT`
  (disk image), not into the build container rootfs that `genapkovl-playos.sh`
  reads from; genapkovl also lacked a bundling block (both added same day).
- **Fix:** stage profiles into container `/etc/playos/device-profiles/` + bundle
  in genapkovl. Verified present in ISO.

### 1.3 playos-shell segfault loop → black screen (the big one)
- **Symptom:** LiveUSB/disk booted to a permanent black screen while all services
  reported "started".
- **Root cause:** `playos-platform-api/src/device_profile.cpp:70` —
  `disp->get("safe_area_insets")->as_table()`. toml++ `table::get()` returns
  `nullptr` for missing keys; `rog-ally.toml` has no `safe_area_insets` → null
  deref, signal 11, compositor respawned the shell forever. Confirmed via
  `dmesg` segfault at address 0, `addr2line` on the ISO binary
  (offset `0xa6ac` → `DeviceProfile::Load`), and a host-side reproducer against
  the real TOML (crashes) and fixed code (loads cleanly).
- **Fix:** rewrote the loader with null-safe `node_view` chaining
  (`root["display"]["safe_area_insets"]`). All `get(key)->member()` patterns in
  that function had the same hazard and were converted.
- **Note:** audit finding **F-008** ("tomlplusplus segfaults on ext4/EROFS, musl-specific,
  keep tmpfs workaround") was very likely this same null deref all along — the
  crash had nothing to do with filesystems. The `/run` tmpfs staging can stay
  (harmless), but the workaround's premise should be revisited.
- **Also affected:** the compositor's input backend calls the same
  `DeviceProfile::Load()` (`linux_input_backend.cpp:302`) — on the Ally it would
  crash the compositor when probing the built-in controller.

### 1.4 iwd daemon not running → wlan0 "unavailable" (WiFi root cause)
- **Symptom:** shell WiFi scan empty; `nmcli device status` → `wlan0  wifi  unavailable`;
  `iwctl` → `Waiting for IWD to start...`; D-Bus activation attempt →
  `Launch helper exited with unknown return code 1`.
- **Root cause (two-phase):**
  1. Original: standalone OpenRC `iwd` service + NM (`wifi.backend=iwd`) in the
     same runlevel with **undefined start order** → NM could not reliably adopt
     the daemon.
  2. First fix attempt (removing the service, relying on NM D-Bus activation)
     **backfired**: on this stack (Alpine 3.24, NM 1.52, iwd 3.12) D-Bus
     activation of iwd fails outright → no daemon at all → device "unavailable".
- **Final fix:** iwd runs as an OpenRC service; a custom
  `alpine/init.d/networkmanager` init script (replacing the Alpine-packaged
  version) polls for iwd's D-Bus name readiness (`net.connman.iwd`) for up to
  10 s before starting NM.  This is stronger than `rc_before` (which only
  orders process startup, not D-Bus registration).  Applied to genapkovl,
  build-alpine-iso.sh, and build-disk-image-alpine.sh.  See
  `docs/boot-analysis-rog-ally-2026-07-30.md` §7.3.
- **Status:** implemented; **hardware confirmation pending**.

### 1.5 PXE deploy picked the wrong ISO
- **Symptom:** build "failed" at the last step; PXE dir had the **arch** ISO
  copied as `alpine-playos-v3.24-x86_64.iso`.
- **Root cause:** Phase 4 used `find out/ -name '*.iso' | head -1` — arbitrary
  pick in a mixed-distro `out/`.
- **Fix:** pick the newest ISO (same pattern as `create-live-usb.sh`).

### 1.6 SSH access baked an unusable key
- **Symptom:** sshd running but `Permission denied (publickey)`.
- **Root cause:** host had no `~/.ssh/*.pub` and `PLAYOS_SSH_PUBKEY` unset →
  scripts fall back to a hardcoded `playos-debug` key whose private half isn't
  on this machine.
- **Fix:** generated `~/.ssh/id_ed25519`; `build-iso-ubuntu.sh` forwards it via
  nspawn env automatically. Verified baked (`nikmes@p340`).

## 2. Robustness / coverage improvements added

- **`cfg80211.ieee80211_regdom=GR`** on all kernel cmdlines (LiveUSB mkimg,
  disk cmdline, bootloader-install cmdline). The default world regdomain (`00`)
  disables EU channels 12/13 and most 5 GHz — APs there are invisible to scans.
- **`rfkill unblock all`** in `playos-async-trigger` before NM/iwd start
  (handhelds can boot with wlan soft-blocked).
- **`linux-firmware-rtl_nic`** added to all package lists — USB-C docks/hubs
  with RTL8153 ethernet need it; without it dock ethernet never comes up.
- **`kms` dropped from the disk initramfs** (`build-disk-image-alpine.sh` sed on
  `mkinitfs.conf`). The LiveUSB (no `kms`) drives the Ally display fine; the
  disk's early-amdgpu path was the only display-path delta for the
  disk-boot black screen. **Candidate fix — hardware retest pending.**
- **`rc_logger="YES"`** on the installed system → `/var/log/rc.log` gives
  post-mortem evidence for boot stalls.
- **`foot` Wayland terminal** packaged and exposed in the shell Library
  (`/playos-samples/build/foot` symlink on LiveUSB, `/data/games/foot` on disk)
  → fullscreen readable terminal on **all** displays (HDMI included), launched
  from the shell UI — replaces squinting at the 7" VT console.
  VT fallback: `XDG_RUNTIME_DIR=/run/playos WAYLAND_DISPLAY=wayland-1 foot &`.

## 3. Hardware / platform gotchas (ROG Ally)

- **USB gadget serial removed**: the Ally's USB-C is host-only — no device-mode/UDC,
  so `g_serial` never produces `ttyGS0`. `playos-usb-gadget` has been removed from all
  build scripts (genapkovl, disk-image, playos-components) and the init script deleted.
- **BIOS doesn't reliably enumerate boot media behind docks**: intermittent at
  best. Boot LiveUSB from the **direct USB-C port**, then hot-plug the dock
  (kernel handles hubs fine post-boot).
- **Monitor auto-source jumps to DisplayPort**: when the compositor exits, the
  HDMI signal drops and the monitor auto-switches inputs ("white funny
  screen"). Not an OS bug — set the monitor to manual HDMI input, or keep the
  compositor alive (foot runs on it).
- **fbcon only binds the internal panel** on VT switch — VT consoles are the
  tiny-font 7" view; use foot instead.
- **`hid-asus-ally.ko` is still only in the disk image**, not on the LiveUSB
  (modloop/initramfs lack it) → built-in gamepad dead on live boot. Open item.

## 4. Ruled out (don't re-chase)

- MT7922 WiFi firmware: present (`WIFI_RAM_CODE_MT7922_1.bin.zst` + patch in
  `linux-firmware-mediatek`); `mt7921e.ko` present in modloop/system.
- Kernel firmware decompression: `CONFIG_FW_LOADER_COMPRESS_ZSTD=y` (verified
  in `linux-stable-7.1.5-r0.apk` config).
- Library closure of compositor/shell: wlroots0.19, libX11 (via mesa-egl),
  libstdc++/libgcc all resolve from the on-ISO repo; `libraylib.so.600` +
  `libglfw.so.3` bundled in apkovl.
- WiFi PSK fidelity: baked value matches `.bashrc` exactly (12 chars, incl.
  special chars). Note: the heredocs are unquoted — a PSK containing `$`,
  backticks, or spaces **would** get mangled. Ours is safe.
- Arch-backend era (07-28/29) git archaeology: no WiFi-relevant regressions in
  `mkimg.playos.sh`/`genapkovl-playos.sh` from that window; runlevel moves were
  benign. Timeline suspect if WiFi *still* fails: **kernel switch 07-26
  `b1e5a82` linux-lts 6.18 → linux-stable 7.1** (mt7921e regression theory).

## 5. Build-system observations

- **Stateful pipeline:** `.build/alpine-rootfs` persists across runs and across
  the Phase 1 → Phase 3 boundary. genapkovl picks up binaries, init scripts,
  and device profiles from the container rootfs — anything not staged there
  silently doesn't make the ISO.
- **Silent conditional includes:** genapkovl wraps everything in `if [ -f ]` —
  missing pieces are skipped without error (this bit us twice: WiFi profile,
  device profiles). Consider logging a summary of included/skipped items.
- **A build killed mid-Phase-3 leaves a *usable* state:** disk image from the
  same run survives; re-running just `build-alpine-iso.sh` in nspawn (with the
  right `--setenv`s) regenerates the ISO in ~5 min instead of a full ~12-min
  pipeline run.
- **Boot flow on LiveUSB:** syslinux/grub cmdline carries
  `softlevel=playos-visual`; OpenRC chain sysinit → boot → playos-visual
  (dbus, seatd, playos-compositor, playos-async-trigger) → async gated by
  `/run/playos-visual-ready` (networkmanager, iwd, sshd; 15 s fallback).
- **Disk-vs-live deltas that mattered:** firstboot service (disk only), `kms`
  initramfs feature (disk only — removed), apk repositories (live = local
  media repo; disk = HTTPS URLs, nothing in boot path uses apk so fine),
  `modloop` semantics.

## 6. Open items / next steps

1. **Verify on hardware:** WiFi scan lists networks + auto-join of
   `messaritisnikhouse` with the ordered-iwd build; then SSH works.
2. **If WiFi still fails:** build with `linux-lts` (6.18) to test the kernel
   regression theory (`mt7921e` on 7.1.x).
3. **Disk boot black screen:** retest with `kms` dropped; if it persists, read
   `/var/log/rc.log` + `/var/log/playos-compositor.log` on the NVMe.
4. **Original disk stall** ("Mounting root: ok"): cause never confirmed —
   `rc.log` from the next attempt will say; `firstboot`'s 30 s nmcli wait can
   never succeed (NM starts in playos-async, *after* the compositor which waits
   on firstboot) — harmless delay, worth reordering.
5. **Ally gamepad on LiveUSB:** include `hid-asus-ally.ko` in the live
   modloop/initramfs.
6. **Commit pending changes** (playos-refdistro batch + playos-platform-api
   segfault fix) — all currently uncommitted working-tree state.
7. Nice-to-have: quote-safe WiFi heredocs; genapkovl include/skip summary log.

## 7. Debugging playbook (reusable)

- **Inspect an ISO's apkovl without booting:**
  `xorriso -osirrox on -indev <iso> -extract /playos.apkovl.tar.gz a.tgz && tar xzf a.tgz -C ovl`
- **Check on-ISO package repo:** extract `/apks/x86_64/APKINDEX.tar.gz`, parse
  `P:`/`D:` stanzas for dependency closure.
- **QEMU harness** (proven): OVMF + virtio-vga + `-display none` +
  `-serial unix:sock,server,nowait` (interactive getty: root, no password) +
  `-monitor unix:sock` (`screendump` → PPM → PNG) +
  `-nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22` (SSH probe).
  Boot to shell ≈ 3–4 min under KVM. llvmpipe renders the real compositor+shell.
- **Symbolizing crashes:** `dmesg` segfault offset → `addr2line -f -C -e <binary> <offset>`
  (binaries on the ISO carry debug_info, not stripped).
- **Device-side with no console:** the Ally has no usable serial/gadget — the
  reliable debug channels are: hub keyboard → VT (tiny), foot on the compositor
  (big), hub ethernet → SSH (needs `linux-firmware-rtl_nic`).
