# Managing disk-unlock methods (passphrases & YubiKeys)

How to add, remove, and audit the ways a machine's encrypted root unlocks,
using only the standard tools (`systemd-cryptenroll`, `cryptsetup`). No
wrappers: these are operations you run rarely and under stress, so it's
worth knowing the real commands — and their traps.

FDE itself is mandatory on machines built with nixos-core (the build fails
without a LUKS volume in the initrd; see `modules/fde.nix`). This guide is
about *how* that volume unlocks.

## The model, in three sentences

The disk is encrypted with a single **volume key**, generated at
`luksFormat` time and never changed by keyslot operations. Each LUKS2
**keyslot** stores a copy of that volume key, wrapped by one unlock secret
(a passphrase, or a FIDO2 token's output). Any one keyslot opens the disk —
so "password and/or YubiKey(s), any combination" is just "which slots
exist".

## Ground rules

- Every command targets the **LUKS partition** (e.g. `/dev/nvme0n1p2`),
  never the mapper (`/dev/mapper/cryptroot`). Targeting the mapper fails.
  Find the partition:

  ```sh
  lsblk -f    # look for the crypto_LUKS row
  ```

- **Always inspect before you remove anything:**

  ```sh
  sudo systemd-cryptenroll /dev/nvme0n1p2
  ```

  This prints a `SLOT TYPE` table — `password` rows are passphrases,
  `fido2` rows are tokens. For full detail: `sudo cryptsetup luksDump
  /dev/nvme0n1p2`.

- **`systemd-cryptenroll` has no seatbelts.** It will wipe the last
  remaining keyslot without a murmur, leaving the data permanently
  unopenable. The invariant is yours to enforce: *after every removal, at
  least one slot you can actually use must remain.* Count rows first.

## Recipes

**Add a passphrase** (also how you re-add one after going token-only):

```sh
sudo systemd-cryptenroll --password /dev/nvme0n1p2
```

**Enroll a FIDO2 token** (YubiKey 5, SoloKey, Token2, …; asks for an
existing passphrase, then the token's PIN and a touch):

```sh
sudo systemd-cryptenroll --fido2-with-client-pin=yes --fido2-device=auto /dev/nvme0n1p2
```

Each enrollment takes its own slot, so repeat per token. Enroll backup
tokens the same way.

**Trap — token-only volumes:** once no passphrase slots exist, the
commands above can't authorize themselves with a passphrase. Tell
systemd-cryptenroll to authorize with the token instead:

```sh
sudo systemd-cryptenroll --unlock-fido2-device=auto --password /dev/nvme0n1p2
```

**Remove one token** (e.g. lost or retired — get its slot number from the
table first):

```sh
sudo systemd-cryptenroll /dev/nvme0n1p2          # note the fido2 slot number
sudo systemd-cryptenroll --wipe-slot=3 /dev/nvme0n1p2
```

`--wipe-slot=fido2` removes *all* tokens at once; `--wipe-slot=password`
removes *all* passphrases at once.

**Use the token at boot:** `core.fde.fido2.enable = true` in the
machine's `configuration.nix` (plus `core.fde.name` if the mapper isn't
"cryptroot"), rebuild, reboot-test — the full block is in
[new-machine.md](new-machine.md) step 5.

## Going token-only (removing the passphrase)

The supported end state "YubiKey only, no password" — done as a checklist,
because the failure mode is unrecoverable data:

1. Enroll **at least two** tokens; keep one offline as a backup.
2. `core.fde.fido2.enable = true`, rebuild, and **reboot-test each token**.
3. Inspect: the table must show your `fido2` slots.
4. Only then:

   ```sh
   sudo systemd-cryptenroll --wipe-slot=password /dev/nvme0n1p2
   ```

From here, losing one of two tokens is routine (wipe its slot, enroll a
replacement). Losing the *only* token is fatal — by design, nobody can
open the disk.

## Odds and ends

- `systemd-cryptenroll --recovery-key` enrolls a machine-generated
  recovery phrase (type `recovery` in the table). Note
  `--wipe-slot=password` does **not** remove it — wipe it by slot number
  or `--wipe-slot=recovery`.
- The initial passphrase you typed during `nixos-install.sh` is a normal
  `password` slot like any other.
