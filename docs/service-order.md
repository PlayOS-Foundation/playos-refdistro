# Service order

## Boot chain

```text
OpenRC boot
  → playos-visual runlevel
      → seatd
      → playos-compositor
          → /usr/bin/playos-compositor --shell /usr/bin/playos-shell --boot-fast
          → signal first-frame readiness
          → start playos-async without blocking the compositor

playos-async runlevel
  → playos-audio
  → playos-network
  → playos-bluetooth
  → playos-library
  → playos-update
```

## Dependency rules

- `playos-compositor` requires local filesystems, device discovery, GPU/input readiness, and `seatd`.
- `playos-compositor` must not require network readiness, Bluetooth, PipeWire, WirePlumber, cloud, or marketplace services.
- `playos-async` starts only after compositor readiness, using a non-blocking OpenRC transition or readiness-triggered helper.
- Individual async services may require compositor readiness, but should not depend on each other unless functionally required (for example, updates require networking).
