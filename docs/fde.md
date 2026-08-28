# Disk unlock (LUKS keyslots)

Each LUKS2 keyslot stores a copy of the volume key, and any one keyslot
opens the disk. Point every command at the LUKS partition (for example
`/dev/nvme0n1p2`; find it with `lsblk -f`).

## Commands

```sh
# Show the keyslot table (password = passphrase, fido2 = token)
sudo systemd-cryptenroll /dev/nvme0n1p2

# Add a passphrase
sudo systemd-cryptenroll --password /dev/nvme0n1p2

# Enroll a FIDO2 token (asks for a passphrase, then PIN + touch; one slot per token)
sudo systemd-cryptenroll --fido2-with-client-pin=yes --fido2-device=auto /dev/nvme0n1p2

# Add a passphrase to a token-only volume (the token authorizes)
sudo systemd-cryptenroll --unlock-fido2-device=auto --password /dev/nvme0n1p2

# Remove one keyslot by number (from the table)
sudo systemd-cryptenroll --wipe-slot=3 /dev/nvme0n1p2

# Remove all keyslots of one type
sudo systemd-cryptenroll --wipe-slot=fido2 /dev/nvme0n1p2
sudo systemd-cryptenroll --wipe-slot=password /dev/nvme0n1p2

# Enroll a recovery phrase (table type "recovery"; wipe it by number or --wipe-slot=recovery)
sudo systemd-cryptenroll --recovery-key /dev/nvme0n1p2
```

## Boot unlock with a token

Set `core.fde.fido2.enable = true` in the machine configuration (and
`core.fde.name` if the mapper differs from "cryptroot"). Rebuild, then
reboot and test. The configuration block is in
[new-machine.md](new-machine.md), step 5.

## Warnings

- `systemd-cryptenroll` wipes the last keyslot on request, and the data
  is then permanently unopenable. Count the table rows before each
  removal.
- Token-only operation: enroll **two** tokens and boot-test each, then
  `--wipe-slot=password`. Loss of the only token loses the data.
- The passphrase from `nixos-install.sh` is a normal `password` slot.
