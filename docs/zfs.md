# ZFS: the install layout, keys and `core.zfs`

The install script puts the system on ZFS. `core.zfs`
([modules/zfs.nix](../modules/zfs.nix)) is what every machine needs
for that; it is on in the template.

## Layout

| Dataset | Mounted at | Encryption |
|---|---|---|
| `rpool` | – | the pool, on the LUKS volume |
| `rpool/local/root` | `/` | LUKS only |
| `rpool/local/nix` | `/nix` | LUKS only |
| `rpool/encrypted` | – | LUKS plus a ZFS key (the encryption root) |
| `rpool/encrypted/home` | `/home` | inherits the key of `rpool/encrypted` |

The tree groups datasets by backup policy, not by directory.
`rpool/local` is what the machine repo rebuilds; it is not
snapshotted and never leaves the machine. `rpool/encrypted` is what
snapshots and replication cover, as one unit (`zfs send -Rw
rpool/encrypted@…`). The root is not wiped at boot, so it still holds
state such as `/var/lib`, `/etc/nixos` and `/etc/zfs/keys`; the
machine repo bundle and the password manager are what bring those
back ([Reinstalling](#reinstalling)).

The pool's properties are inherited by every dataset: `ashift=12`,
`compression=zstd`, `atime=off`, `xattr=sa` with `dnodesize=auto`,
`acltype=posixacl`, `normalization=formD`, and `autotrim=on`. The
datasets have legacy mountpoints, so `nixos-generate-config` emits
them as `fileSystems` and systemd orders the mounts. Other pools
(data disks) are the machine's business; `core.zfs.pools` lists them
for import at boot.

LUKS stays under the pool. It is what the mandatory-FDE assertion and
the FIDO2 unlock ([fde.md](fde.md)) work on, and it hides what ZFS
native encryption leaves visible, such as dataset names and sizes.

`rpool/encrypted` has ZFS encryption on top, under its own
passphrase, for one reason: a raw send of it (`zfs send -w`) is
ciphertext wherever it lands, so homes can be replicated to a machine
that cannot read them. It is the encryption root of everything under
it: a dataset created there inherits the key, and ZFS refuses an
unencrypted one, so whatever is added to the backed-up side later is
encrypted without anyone remembering to. (A child can still get a key
of its own with `zfs change-key`.) The passphrase lives in
`/etc/zfs/keys/encrypted` on the encrypted root, mode 600, and is
loaded at boot by `core.zfs.unlock`; the disk passphrase at boot stays
the only interactive step. The install script generates it and prints
it once. The same pattern serves other encrypted datasets: key file
under `/etc/zfs/keys`, encryption root in `core.zfs.unlock`.

> [!CAUTION]
> **BACK UP THE KEY OF `rpool/encrypted`. WITHOUT IT, EVERY BACKUP OF
> `/home` IS PERMANENTLY UNREADABLE.**
>
> A raw send carries the ciphertext, not the key. The only copy on the
> machine is `/etc/zfs/keys/encrypted`, which goes with a dead disk, a
> lost machine or a reinstall. Nothing else can decrypt the backups:
> not the disk passphrase, not a YubiKey, not anyone else. Store the key
> in a password manager on another device when the install script
> prints it, or later with `sudo cat /etc/zfs/keys/encrypted`. The same
> goes for the key of every other dataset in `core.zfs.unlock`.

## `core.zfs`

```nix
core.zfs.enable = true;
core.zfs.unlock = [ "rpool/encrypted" ];   # keys loaded after import, before the mounts under them
core.zfs.pools = [ "tank" ];          # pools besides those fileSystems needs
core.zfs.scrubInterval = "monthly";
```

- **hostId** defaults to the first eight hex digits of the hostname's
  SHA-256. ZFS refuses to import a pool last used by another hostId; a
  stable, derived value means a reinstalled machine imports its pools
  with no `-f` and nothing to remember. The install script pins the
  value as `networking.hostId` in `hardware-configuration.nix`, so
  renaming the machine keeps it, and a reinstall from the machine repo
  carries the old value over. It also exports the pool at the end, so
  the first boot imports it regardless of the live system's hostId.
- **Root pool import** in the initrd waits for the LUKS unlock
  (`cryptsetup.target`), so the passphrase or FIDO2 prompt can take as
  long as it needs; without that, nixpkgs' import gives up after about
  a minute and the boot drops into emergency mode.
- **Key loading** happens in stage 2, from one service per dataset in
  `core.zfs.unlock` (`core-zfs-load-key-<dataset>`), ordered before
  `zfs-mount.service` and before the mount units of the dataset and
  of every dataset under it, so `rpool/encrypted`, which is never
  mounted itself, holds back `/home`. It loads the key of the
  dataset's encryption root, which may be a parent, and skips a
  dataset that is not encrypted. The NixOS default would load keys at import,
  in the initrd for the root pool, where `/etc/zfs/keys` is not
  mounted yet; it is also off so that a dataset whose key is not on
  this machine does not stop the boot at a prompt. A dataset on the
  root pool does not wait for `zfs-import.target`, which also waits
  for the data pools' import timeouts.
- **A missing or wrong key file** for a dataset in `fileSystems`
  fails that mount and drops the boot into emergency mode. For a
  dataset mounted by its own `mountpoint` property, the key service
  fails, the dataset stays unmounted, and its mountpoint is an empty
  directory on the root.
- **Kernel**: nixpkgs builds ZFS against the default (LTS) kernel and
  the build fails loudly if a machine picks a kernel ZFS does not
  support yet, so `boot.kernelPackages = pkgs.linuxPackages_latest`
  may have to wait for ZFS.
- **TRIM**: the pool has `autotrim=on` and `zpool-trim` runs weekly;
  `zpool trim` skips devices without TRIM, so spinning disks are fine.
  The discards pass through LUKS because the install script sets
  `allowDiscards` on the root volume; that reveals which blocks are
  free, not what the others hold.
- **Without the install script's layout** (a root not on
  `rpool`): remove `core.zfs.unlock = [ "rpool/encrypted" ]` from
  `configuration.nix`, or its key service fails at every boot, and
  `core.zfs.enable` as well if there is no ZFS at all.

## Reinstalling

The machine repo and the key files are the two things on the root
that a reinstall needs again. The repo goes off as a bundle
([new-machine.md](new-machine.md)); the key of any dataset the new
root must unlock (a data pool's, say) is recreated from the password
manager as `/mnt/etc/zfs/keys/<name>`, mode 600, from the review
shell. `rpool/encrypted` gets a new key with the new install; the old home
comes back from a backup with the old passphrase.

```sh
sudo zpool status                        # health
sudo zfs get -r keystatus,encryptionroot rpool
systemctl list-timers 'zfs-*' 'zpool-*'
```
