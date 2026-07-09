# PlayOS fast visual boot

PlayOS does not wait for the system to be ready. PlayOS makes the screen ready first.

## Critical path

```
root filesystem
udev coldplug enough for GPU/input
DRM/KMS device
seat access
playos-compositor
playos-shell first frame
```

## Async services

These start after the first shell frame is visible:

- audio (PipeWire + WirePlumber)
- network (NetworkManager)
- Bluetooth (bluez)
- cloud services
- marketplace
- library scanning
- updates
- telemetry
- SSH/debug
