# VirtualBox boot test

## VM configuration

| Setting | Value |
|---------|-------|
| Name | PlayOS-Test |
| Type | Linux |
| Version | Arch Linux (64-bit) |
| RAM | 4096 MB minimum |
| CPU | 2-4 cores |
| Firmware | Enable EFI (special OSes only) |
| Disk | Optional for live ISO test |
| Optical drive | Attach generated ISO from `out/` |
| Graphics controller | VMSVGA |
| Video memory | 128 MB |
| Network | NAT |

## Validation steps

1. Attach the generated ISO to the optical drive
2. Boot the VM
3. Verify the ISO boots to the shell placeholder
4. Inside the booted ISO, run:

```bash
systemctl status playos-compositor.service
systemctl status playos-async.target
systemd-analyze
systemd-analyze critical-chain
journalctl -b -u playos-compositor.service
/usr/bin/playos-boot-report
```

5. Confirm `playos-async.target` started after the compositor
6. Confirm no `network-online.target` dependency blocked boot
