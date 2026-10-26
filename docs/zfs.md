# ZFS data pools: `core.zfs`

The root stays on btrfs. ZFS is for pools on other attached drives.
`core.zfs` ([modules/zfs.nix](../modules/zfs.nix)) is the support
every such machine needs.

## `core.zfs`

```nix
core.zfs.enable = true;
core.zfs.pools = [ "tank" ];              # imported at boot
core.zfs.unlock = [ "tank/encrypted" ];   # encryption roots whose keys load at import
core.zfs.scrubInterval = "monthly";
```

- **hostId** defaults to the first eight hex digits of the hostname's
  SHA-256. ZFS refuses to import a pool last used by another hostId; a
  stable, derived value means a reinstalled machine imports its pools
  with no `-f` and nothing to remember. A renamed machine imports its
  pools once by hand with `zpool import -f <pool>`, or pins the old
  value as `networking.hostId`; the import service fails until then,
  the boot does not.
- **Key loading** is nixpkgs' own: `core.zfs.unlock` is passed as
  `boot.zfs.requestEncryptionCredentials`, so `zfs-import-<pool>`
  loads the key of each listed encryption root right after importing
  the pool, before `zfs-mount.service`. Datasets under a root inherit
  its key. The key is a passphrase in a root-only file under
  `/etc/zfs/keys`, on the LUKS-encrypted root, so the disk passphrase
  at boot stays the only interactive step. Encrypted datasets that are
  not listed stay locked, so a dataset whose key is not on this
  machine (a raw-received backup) does not stop the boot at a prompt.
- **A missing or wrong key file** fails `zfs-import-<pool>` (the pool
  is imported regardless). The dataset stays unmounted and its
  mountpoint is an empty directory on the root; anything that writes
  there lands on the root disk.
- **Kernel**: nixpkgs builds ZFS against the default (LTS) kernel and
  the build fails loudly if a machine picks a kernel ZFS does not
  support yet, so `boot.kernelPackages = pkgs.linuxPackages_latest`
  may have to wait for ZFS.
- **TRIM**: `zpool-trim` runs weekly; `zpool trim` skips devices
  without TRIM, so spinning disks are fine.

## Reinstalling

The pool survives a reinstall of the root; the key files under
`/etc/zfs/keys` do not. Recreate each from the password manager, one
line holding the passphrase, mode 600, then load and mount:

```sh
sudo install -d -m 700 /etc/zfs/keys
sudo sh -c 'umask 077; cat > /etc/zfs/keys/tank-encrypted'   # paste, then Ctrl-D
sudo zfs load-key tank/encrypted && sudo zfs mount -a
```

The next boot loads it on its own.

```sh
sudo zpool status                              # health
sudo zfs get -r keystatus,encryptionroot tank
systemctl list-timers 'zfs-*' 'zpool-*'
```
