# Roadmap

## Current baseline

- Alpine `v3.24` image tooling produces a compressed GPT disk image and a
  bootable ISO.
- Ubuntu uses a pinned Alpine minirootfs through `systemd-nspawn`.
- The build compiles sibling PlayOS components against musl and bundles the
  compositor, Shell, and samples.
- The disk image uses systemd-boot, a separate data partition, and one-shot
  first-boot initialization.

## Next milestones

1. **Migrate Raylib to 6.0 via custom APKBUILD.** Alpine 3.24 ships raylib
   5.0-r0 only. Create a custom `alpine/apkbuilds/raylib/APKBUILD` for 6.0,
   update soname references (`libraylib.so.450` → `libraylib.so.600`) in
   `genapkovl-playos.sh`, `build-disk-image.sh`, and `playos-installer`,
   then integrate the custom repo into `build-playos-components.sh`. Also
   update `playos-shell/gen-context.md` and `playos-spec` book chapter for
   the new version. See `mig2raylib6.md` for the full plan.
2. Build the existing ISO and disk image, then validate the artifacts and boot
   path in QEMU.
3. Record reproducible build inputs and validation evidence for that baseline
   image.
4. Complete ROG Ally hardware testing only after QEMU validation passes for
   device-facing changes. See [ROG Ally driver integration](#rog-ally-driver-integration)
   below for the kernel and controller driver work that feeds into this milestone.
5. Move non-visual services to a readiness-triggered `playos-async` path so
   networking, SSH, audio, Bluetooth, and background features cannot affect
   first-frame latency.
6. Replace direct binary copying with signed PlayOS APK packages built from
   pinned sources.

## ROG Ally driver integration

ROG Ally hardware has specific kernel driver needs beyond what the base Alpine
image provides. A comprehensive driver survey is in
[`ROG-LinuxDriverSupport.md`](ROG-LinuxDriverSupport.md); hardware findings
that drive these priorities are in
[`docs/hardware/rog-ally.md`](docs/hardware/rog-ally.md).

### Phase 1: Switch `linux-lts` → `linux-stable` (unlocks `asus-armoury`)

Alpine v3.24 community ships `linux-stable 7.1.4`, which includes the
`asus-armoury` platform driver (mainlined in 6.19). This gives us advanced
TDP controls (core count, APU memory, dGPU TGP) without a custom kernel build.

**Files to change (7):**

| File | Change |
|---|---|
| `alpine/mkimg.playos.sh` | `kernel_flavors="lts"` → `"stable"` |
| `scripts/build-disk-image.sh` | `linux-lts` → `linux-stable` apk; all `vmlinuz-lts`/`initramfs-lts` → `-stable` |
| `scripts/build-iso-ubuntu.sh` | All `vmlinuz-lts`/`initramfs-lts`/`modloop-lts` → `-stable` |
| `alpine/boot.ipxe` | All `-lts` suffixes → `-stable` |
| `alpine/boot-debug.ipxe` | All `-lts` suffixes → `-stable` |
| `scripts/verify-build.sh` | Update expected artifact filenames |
| `scripts/build-playos-components.sh` | Add `linux-stable-dev` for kernel headers (if needed) |

**Risk:** `linux-stable` is in community (not main) and kernel 7.1.4 is
untested on ROG Ally. QEMU validation required before hardware testing.

### Phase 2: `hid-asus-ally` APKBUILD (controller features)

The ROG Ally controller needs a device-specific HID driver to expose back
paddles (M1/M2), gyroscope, ROG Crate, and Command Center buttons. The xpad
driver only exposes standard Xbox 360 inputs. This driver is out-of-tree and
must be built against the running kernel.

**Files to create/change (5):**

| File | Change |
|---|---|
| `alpine/apkbuilds/hid-asus-ally/APKBUILD` | New — build against `linux-stable-dev`, produce `.apk` |
| `scripts/build-playos-components.sh` | Register custom APK repo, add `hid-asus-ally` package |
| `alpine/mkimg.playos.sh` | Add `hid-asus-ally` to apks list |
| `scripts/build-disk-image.sh` | Add `hid-asus-ally` to `apk add` list |
| `alpine/genapkovl-playos.sh` | Bundle kernel module in live ISO overlay |

**Risk:** Out-of-tree module may need patches for kernel 7.1. Driver is
maintained but not yet mainlined.

### Phase 3: Raylib 5.0 → 6.0 migration

Independent of the kernel work. See [`mig2raylib6.md`](mig2raylib6.md) for
the full plan — custom APKBUILD + soname updates across 6 files.

### Phase 4: Build + QEMU validation

```bash
bash scripts/build-iso-ubuntu.sh         # Full pipeline (image + ISO + PXE)
bash scripts/verify-build.sh              # Artifact integrity checks
bash scripts/test-disk-image-qemu.sh      # Disk image boot test
bash scripts/test-iso-qemu.sh             # ISO boot test
```

### Dependency order

```
Phase 1 (kernel switch) ──→ Phase 2 (hid-asus-ally)
                                        │
Phase 3 (raylib 6.0) ───────────────────┤
                                        │
                                        └──→ Phase 4 (validate)
```

Phase 1 must complete first — Phase 2 builds against the new kernel headers.
Phase 3 is independent and can run in parallel.

## Documentation

The current build, image, boot, and validation model is documented in
[`docs/README.md`](docs/README.md).
