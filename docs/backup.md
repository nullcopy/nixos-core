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
  its own policy, with its own account. A compromised sender can stop sending; it
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
| `tank/encrypted` | this machine's own data; what replication covers | its own key, a passphrase in `/etc/zfs/keys/tank-encrypted` on the LUKS root | at `/tank` |
| `tank/recv/<peer>` | raw backups from `<peer>` | the peer's key, never loaded here | never |

`tank/encrypted` is what a machine sends to its peers; `core-zpool`
creates it ([zfs.md](zfs.md)). Its key file lives on the root volume,
which LUKS already encrypts at rest, so unlocking the root at boot is
the only interactive step (`core.zfs.unlock` loads it). Record the
same passphrase in a password manager: it is what makes a backup
restorable after the machine that held the file is gone.

## Pairing

Which senders a receiver accepts is state on the receiver, managed
with `core-backup`; no repository changes when a machine joins. Each
sender has a backup key, `/var/lib/backup/key`, which its sends log
in with; for now it is made by hand (see Sending by hand). It is separate
from the host key because the syncoid process that uses it is
unprivileged and parses what remote machines send it; what it holds
is an identity that can only append to its own backups.

The key travels over [magic-wormhole](https://magic-wormhole.readthedocs.io),
in the same exchange as `wormhole ssh invite`. On the receiver:

```sh
sudo core-backup invite hawkeye --quota 6T
```

It prints a code. On the sender, either of:

```sh
core-backup join 7-guitarist-revenge
wormhole ssh accept -F /var/lib/backup 7-guitarist-revenge
```

The second needs only stock magic-wormhole, so it works on a machine
that is not on nixos-core. The receiver shows the key's fingerprint
and asks before accepting it (`--yes` skips the question). The
wormhole code authenticates both ends, so the key that arrives is the
one that was sent. `core-backup accept NAME 'ssh-ed25519 …'` does the
same with a key copied by other means.

The name must be the sender's hostname: its sends log in as
`recv-<name>` and land in `tank/recv/<name>`. Accepting creates that
system account (uid in 55000–55999, no home, no password), the
dataset, the delegation and the quota, and writes the key, prefixed
with `restrict`, to `/var/lib/backup/authorized_keys/recv-<name>`,
which sshd reads. The state lives in `/var/lib/backup/recv/<name>`.

```sh
sudo core-backup list              # name, quota, space used, newest snapshot
sudo core-backup revoke hawkeye    # stops its sends; tank/recv/hawkeye stays
```

The sender trusts the receiver's host key on first use and pins it in
`/var/lib/syncoid/known_hosts`. Peers are reached over the tailnet,
whose WireGuard identities already authenticate the address.

## Setting up a receiver

In the machine's `configuration.nix`:

```nix
core.zfs.enable = true;
core.zfs.pools = [ "tank" ];                 # imported at boot; nothing on it mounts
core.zfs.unlock = [ "tank/encrypted" ];          # only if tank/encrypted exists
core.backup.receive.enable = true;
services.openssh.enable = true;
```

Rebuild, then create the pool with `core-zpool` ([zfs.md](zfs.md)),
with `--no-encrypted` for a machine that only receives. Compression
on the pool is for `tank/encrypted`; raw-received datasets carry the
sender's blocks and ignore it.

Then pair senders. At every boot, `backup-receive-setup.service`
recreates `tank/recv` and, for each accepted sender, its key file,
dataset, delegation (reset to exactly the list in `core-backup`) and
quota. The quota is a ZFS `quota` on the sender's dataset, which the
sender cannot change; without one, a runaway or compromised sender
fills the pool.

`sanoid` prunes the received snapshots daily by
`core.backup.receive.retention` (60 daily, 24 monthly, 3 yearly by
default). The NixOS module runs it as its own user with `snapshot`,
`mount` and `destroy` delegated on `tank/recv` for the run; it takes
no snapshots of its own there and leaves snapshots that are not
sanoid-named (such as a manual `@backup-2026-10-21`) alone.

## Sending by hand

From a machine with ZFS, as root. The identity is a backup key,
paired with the receiver as above:

```sh
install -d -m 755 /var/lib/backup
ssh-keygen -t ed25519 -N "" -C "backup@$(hostname)" -f /var/lib/backup/key
wormhole ssh accept -F /var/lib/backup <code from core-backup invite>
```

```sh
SNAP=backup-$(date +%F)
zfs snapshot -r tank/encrypted@$SNAP
zfs send -w -R tank/encrypted@$SNAP | pv | \
  ssh -i /var/lib/backup/key recv-<me>@<receiver> \
    zfs receive -u -s tank/recv/<me>/encrypted
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
tank/encrypted@$SNAP` into the same destination. With
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
  `{ "tank/encrypted" = [ "obelisk" ]; }`, makes the backup key at
  first boot, forces raw sends, and refuses an unencrypted source. With
  sanoid snapshots on the sender.
- Alerts: `OnFailure=` on the send unit, and a receiver-side timer
  that flags a peer whose newest snapshot is older than a threshold.
  The second catches a dead sender, which the first cannot.
- ZED notifications for degraded pools and failed scrubs.
