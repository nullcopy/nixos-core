# ZFS-native backups between machines

Machines back each other up with ZFS replication. A sender pushes raw
streams (`zfs send -w`) of its encrypted datasets to a receiver over
SSH on the tailnet. A raw stream is the encrypted blocks as they sit
on disk, plus the wrapped key material; the receiver stores them as an
encrypted dataset whose key it never has. It can scrub, resilver,
snapshot and prune what it holds, and read none of it. The only things
it learns are dataset and snapshot names, sizes and property values.

Two choices follow from that:

- **Senders push; receivers never pull.** A puller would hold an SSH
  login on the sender, where the key is loaded during normal
  operation, and a `zfs send` without `-w` from that login would give
  it plaintext. Every credential points the safe way.
- **A sender cannot destroy what it sent.** It logs in as a
  per-sender account with delegated `zfs` permissions that exclude
  `destroy`, `rollback` and forced receives. The receiver prunes under
  its own policy, as root. A compromised sender can stop sending; it
  cannot take its history on the receiver with it.

The modules: `core.zfs` ([modules/zfs.nix](../modules/zfs.nix)) and
`core.backup` ([modules/backup.nix](../modules/backup.nix)). The
sending side runs by hand today; a `core.backup.send` module is the
next step (see "Not yet" at the end).

## Pool layout

The same names on every machine, so modules and procedures carry
over:

| Dataset | Holds | Encryption | Mounted |
|---|---|---|---|
| `tank` | the data pool; nothing directly | – | no (`canmount=off`) |
| `tank/local` | this machine's own data | its own key, a passphrase in `/etc/zfs/keys/tank-local` on the LUKS root | at `/tank` |
| `tank/recv/<peer>` | raw backups from `<peer>` | the peer's key, never loaded here | never |

`tank/local` is what a machine sends to its peers. Its key file lives
on the root volume, which LUKS already encrypts at rest, so unlocking
the root at boot is the only interactive step (`core.zfs.unlock`
loads it). Record the same passphrase in a password manager: it is
what makes a backup restorable after the machine that held the file
is gone.

A machine without data disks has no `tank`; the plan is for every
machine's home to live on an encrypted `rpool/home` and be sent the
same way (not yet, see the end).

## The peer registry

[peers.nix](../peers.nix) lists every machine by name with its SSH
host public key (`/etc/ssh/ssh_host_ed25519_key.pub`) and, if the
tailnet name is not enough, an address. Public keys only.

The host key does double duty. Receivers accept it as the login key
of `recv-<name>`; senders present it as their client identity and
verify it as the host key of `<name>`. Every machine on nixos-core
gets the registry as `programs.ssh.knownHosts`, so no sender ever
sees a trust-on-first-use prompt. Adding a machine to the network is
one commit: its line in `peers.nix`.

## Setting up a receiver

In the machine's `configuration.nix`:

```nix
core.zfs.enable = true;
core.zfs.pools = [ "tank" ];                 # imported at boot; nothing on it mounts
core.zfs.unlock = [ "tank/local" ];          # only if tank/local exists
core.backup.receive.enable = true;
core.backup.receive.from = [ "hawkeye" ];    # names from peers.nix
services.openssh.enable = true;
```

Rebuild, then create the pool once by hand. Use `/dev/disk/by-id`
names; `wipefs -a` and `sgdisk --zap-all` the disks first if they
have a past.

```sh
sudo zpool create -o ashift=12 \
  -O mountpoint=none -O canmount=off -O atime=off \
  -O xattr=sa -O acltype=posixacl \
  tank mirror /dev/disk/by-id/<disk-a> /dev/disk/by-id/<disk-b>

# Local data (optional on a pure backup target).
sudo install -d -m 700 /etc/zfs/keys
umask 077; head -c 32 /dev/urandom | base64 | sudo tee /etc/zfs/keys/tank-local >/dev/null
sudo zfs create -o mountpoint=/tank \
  -o encryption=aes-256-gcm -o keyformat=passphrase \
  -o keylocation=file:///etc/zfs/keys/tank-local tank/local
```

Compression on the pool is pointless for received data; a raw stream
carries the sender's compressed blocks.

Then `sudo systemctl start backup-receive-setup`, or reboot. That
service creates `tank/recv` and `tank/recv/<peer>` for every accepted
peer and delegates the receive permissions to `recv-<peer>`. It runs
at every boot, so a peer added to `from` later needs only a rebuild.
`zfs allow` only adds; a permission dropped from the module's list is
removed by hand once with `zfs unallow`.

`sanoid` prunes the received snapshots daily by
`core.backup.receive.retention` (60 daily, 24 monthly, 3 yearly by
default). It takes no snapshots of its own there and leaves snapshots
that are not sanoid-named (such as a manual `@backup-2026-10-21`)
alone.

## Sending by hand

From a machine with ZFS, as root. The host key is the identity; the
receiver has it in `peers.nix`.

```sh
SNAP=backup-$(date +%F)
zfs snapshot -r tank/local@$SNAP
zfs send -w -R tank/local@$SNAP | pv | \
  ssh -i /etc/ssh/ssh_host_ed25519_key recv-<me>@<receiver> \
    zfs receive -u -s tank/recv/<me>/local
```

- `-w` is raw. The first stream of a dataset decides: raw sends and
  non-raw sends cannot be mixed in one incremental chain, so always
  send raw.
- `-R` carries every child dataset, every snapshot and the
  properties.
- `-u` on the receive skips mounting, which could not succeed without
  the key anyway. `-s` makes an interrupted receive resumable: read
  the token with `zfs get receive_resume_token` on the receiver and
  continue with `zfs send -w -t <token>`.
- The receiver account cannot delete a half-received dataset. If a
  send has to start over rather than resume, root on the receiver
  runs `zfs destroy -r` on it.
- A full send of several terabytes takes hours. Run it in `tmux`.

Later sends are incremental: `zfs send -w -R -I @previous
tank/local@$SNAP` into the same destination. With
[syncoid](https://github.com/jimsalterjrs/sanoid), the equivalent is
`syncoid -r --no-sync-snap --no-rollback --sendoptions=w
--recvoptions=u --no-privilege-elevation`, which is what the sending
module will run.

## Verifying a receiver is blind

On the receiver, after the first send:

```sh
sudo zfs get -r encryption,keystatus,encryptionroot,mounted tank/recv
sudo zfs mount tank/recv/<peer>/local     # must fail: key not loaded
```

`keystatus` is `unavailable` on every received dataset. Never run
`zfs load-key` on a received dataset: the raw stream carries the
sender's wrapped key, so the sender's passphrase would unlock it here
too. Blindness is a rule on the receiver, not an impossibility.

## Restoring

A restore is a raw send in the other direction, to the original
machine or to any fresh pool, followed by `zfs load-key` with the
sender's passphrase there. Nothing on the receiver is needed beyond
the datasets, which is why the passphrase must exist somewhere other
than the machine it protects.

## Not yet

- `core.backup.send`: a wrapper around `services.syncoid` that takes
  `{ "tank/local" = [ "obelisk" ]; }`, resolves targets through the
  registry, forces raw sends, and refuses an unencrypted source. With
  sanoid snapshots on the sender.
- Alerts: `OnFailure=` on the send unit, and a receiver-side timer
  that flags a peer whose newest snapshot is older than a threshold.
  The second catches a dead sender, which the first cannot.
- ZFS root in the install script: `rpool` on the LUKS mapper with an
  encrypted `rpool/home`, so every machine's homes are sendable the
  same way. Non-root users can then run their own sends with
  `zfs allow -u <user> send,snapshot,hold,bookmark` on their dataset.
- ZED notifications for degraded pools and failed scrubs.
