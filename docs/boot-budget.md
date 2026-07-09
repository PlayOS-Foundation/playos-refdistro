# Boot budget

## Targets

| Metric | v0.1 acceptable | Target reference device |
|--------|----------------|------------------------|
| Cold boot to first shell frame | Under 8 seconds | Under 3 seconds |
| Resume to shell | Under 3 seconds | Under 1 second |

## Cold boot breakdown (target)

| Time | Milestone |
|------|-----------|
| 0.0 s | UEFI handoff |
| 0.3 s | Kernel init |
| 0.5 s | systemd starts, local-fs.target reached |
| 0.8 s | udev triggers complete (GPU + input only) |
| 1.0 s | seatd starts |
| 1.5 s | playos-compositor takes DRM/KMS |
| 2.0 s | First shell frame visible |

## Enforcement

Any service added to the visual boot path must be measured and documented
here before merging. Services that cannot meet the 2-second budget belong
in `playos-async.target`.
