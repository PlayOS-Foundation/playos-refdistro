# VirtualBox boot test

## VM configuration

| Setting | Value |
|---------|-------|
| Name | PlayOS-Test |
| Type | Linux |
| Version | Other Linux (64-bit) |
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
rc-status --all
rc-service seatd status
dmesg | tail -n 100
/usr/bin/playos-boot-report
```

5. Once compositor packages are present, confirm `playos-async` started after compositor readiness
6. Confirm network readiness did not block the visual boot path
