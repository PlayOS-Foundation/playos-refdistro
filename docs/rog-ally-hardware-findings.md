# ROG Ally hardware findings

These distribution-neutral observations were extracted before retiring the Arch profile. They are hypotheses and validation requirements for the Alpine implementation, not fixes to copy verbatim.

- The reference device uses AMD Phoenix graphics. Validate that the final image supplies the matching kernel module and firmware through Alpine packages, initramfs, and modloop inputs.
- USB Ethernet adapters using `r8152` may enumerate after early userspace begins. PXE and recovery flows should use a bounded wait for interface and link readiness.
- Network-dependent boot steps should verify interface, route, and DNS readiness and must remain outside the first-frame path.
- Validate firmware and kernel-module integrity from the produced image, not only from the build root.
- Do not vendor firmware blobs or kernel modules into this repository. Resolve them through pinned Alpine packages and record the resulting versions.

The retired implementation and tool-specific debugging details remain available in Git history.
