# Service order

## Boot chain

```
playos-visual.target (default)
  → seatd.service
  → playos-compositor.service
      → /usr/bin/playos-compositor --shell /usr/bin/playos-shell --boot-fast
      → ExecStartPost: systemctl --no-block start playos-async.target

playos-async.target
  → playos-audio.service
  → playos-network.service
  → playos-bluetooth.service
  → playos-library.service
  → playos-update.service
```

## Dependency rules

- `playos-compositor.service` depends on: `local-fs.target`, `systemd-udevd.service`, `systemd-udev-trigger.service`, `seatd.service`
- `playos-compositor.service` must NOT depend on: `network-online.target`, `NetworkManager-wait-online.service`, `bluetooth.service`, `pipewire`, `wireplumber`, cloud services, marketplace services
- `playos-async.target` starts after `playos-compositor.service`
- Individual async services may depend on `playos-compositor.service` but never on each other (unless required, e.g. update needs network)
