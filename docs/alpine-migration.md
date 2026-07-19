# Alpine migration

ADR-0004 replaces Arch with Alpine as the PlayOS reference OS base.

## What is preserved

The existing `archiso/` tree and Arch builder remain temporarily as regression material because they contain a ROG Ally-verified compositor/shell path, device-profile handling, firmware fixes, and boot measurements.

No Git history will be rewritten.

## Phases

### A. Alpine image baseline

- [x] Pin Alpine 3.24 builder.
- [x] Add aports/mkimage profile.
- [x] Add OpenRC visual and async runlevels.
- [ ] Build ISO reproducibly.
- [ ] Boot with UEFI in QEMU/OVMF.
- [ ] Boot in VirtualBox.

### B. musl-native PlayOS packages

- [ ] Add APKBUILDs and a signed local repository.
- [ ] Build platform API on musl.
- [ ] Build runtime and compositor on musl.
- [ ] Build Raylib shell and samples on musl.
- [ ] Add compositor and shell to `playos-visual`.
- [ ] Emit an explicit compositor/shell readiness signal.

### C. ROG Ally parity

- [ ] Load amdgpu and required firmware.
- [ ] Confirm EGL/GLES hardware renderer.
- [ ] Map internal panel and 60/120 Hz modes.
- [ ] Route built-in controller, Home, and touch.
- [ ] Launch a sample and return to the live shell.
- [ ] Measure cold boot to first interactive frame.

### D. Services and persistence

- [ ] PipeWire/WirePlumber.
- [ ] NetworkManager/iwd.
- [ ] BlueZ controller pairing.
- [ ] Suspend/resume.
- [ ] Dock and external display.
- [ ] Separate persistent PlayOS data partition.
- [ ] Recovery and signed update flow.

### E. Arch retirement

The active Arch files may be removed only after all A–D gates required for the current release are green and the Alpine image has passed repeated hardware testing. Removal must be a normal reviewed commit; history remains recoverable.

## Compatibility

The host is musl-based. glibc-only payloads belong in declared compatibility runtimes. Do not add glibc to the base OS as an undocumented ABI.
