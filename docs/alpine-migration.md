# Alpine migration

ADR-0004 replaces Arch with Alpine as the PlayOS reference OS base.

## Archive policy

The Arch profile and its build artifacts have been removed from the active tree. Git history is the canonical archive; no history is rewritten. Distribution-neutral device findings are retained as documentation and must be revalidated against Alpine rather than copied as Arch-specific workarounds.

## Phases

### A. Alpine image baseline

- [x] Pin Alpine 3.24 builder.
- [x] Add aports/mkimage profile.
- [x] Add OpenRC visual and async runlevels.
- [x] Add Docker-free native Ubuntu Server wrappers.
- [x] Add headless serial QEMU/OVMF wrapper.
- [ ] Build ISO reproducibly on Ubuntu Server.
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

### E. PXE

- [ ] Export kernel, initramfs, modloop, APK repository, and apkovl.
- [ ] Add a netboot.xyz custom menu entry.
- [ ] Verify PXE and ISO consume identical build inputs.
- [ ] Boot over Ethernet on the ROG Ally/dock.

### F. Future distro profiles

A future Arch or other distro profile requires a new proposal and an independently maintained packaging, image, init/service, validation, and release path. Reintroducing an old profile from history is not sufficient.

## Compatibility

The host is musl-based. glibc-only payloads belong in declared compatibility runtimes. Do not add glibc to the base OS as an undocumented ABI.
