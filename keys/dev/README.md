# PlayOS development signing keys (Sprint 12)

These keys are **development only**. Production signing uses an
HSM-backed key and is explicitly post-MVP (see
`playos-spec/src/security-model.md` and `Sprint-12.md` T9).

| File | Purpose | Private? |
|---|---|---|
| `efi-signing-key.pem`  | EFI/UEFI Secure Boot signing (used by `scripts/sign-efi.sh` with `sbsign`) | yes — dev only |
| `efi-signing-cert.pem` | Self-signed certificate matching the key; enroll with `mokutil`/firmware to trust dev-signed `BOOTX64.EFI` | no |
| `manifest-key.pub`     | Ed25519 public key embedded in `playos-init` (`src/security/game_key.h`) for warn-only manifest verification | no |
| `manifest-key.sec`     | Ed25519 seed (hex) used by `scripts/sign-manifest.sh` | yes — dev only |

Regenerate (dev keys only):

```sh
openssl req -x509 -newkey rsa:2048 \
    -keyout keys/dev/efi-signing-key.pem \
    -out keys/dev/efi-signing-cert.pem \
    -days 3650 -nodes -subj "/CN=PlayOS Development EFI Signing Key/O=PlayOS/OU=Development"
# manifest key: 32 random bytes; update playos-init/src/security/game_key.h
# with the derived public key after generating.
```

Never copy these keys into production images or CI artifacts that ship to
users; production signing stays on the HSM (post-MVP).
