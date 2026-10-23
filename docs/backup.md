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

The modules, all in [modules/](../modules):

| Option | Module | Does |
|---|---|---|
| `core.zfs` | zfs.nix | ZFS itself: hostId, pool import, key loading, scrubs, pool-event alerts, the `core-zpool` wizard |
| `core.backup.receive` | backup.nix | accept raw replication from peers into `tank/recv/<peer>` |
| `core.backup.send` | backup-send.nix | push raw replication of this machine's datasets to peers |
| `core.alerts` | alerts.nix | where failed units, stale backups and pool events are reported |

## Pool layout

The same names on every machine, so modules and procedures carry
over. The install script creates `rpool`; `core-zpool` creates
`tank`.

| Dataset | Holds | Encryption | Mounted |
|---|---|---|---|
| `rpool` | the root pool, on the LUKS volume | LUKS underneath | – |
| `rpool/root`, `rpool/nix`, `rpool/log` | the system | LUKS only | `/`, `/nix`, `/var/log` |
| `rpool/home` | every user's home | LUKS plus its own ZFS key, `/etc/zfs/keys/home` | `/home` |
| `tank` | the data pool, on the data disks | – | no |
| `tank/local` | this machine's own data | its own ZFS key, `/etc/zfs/keys/tank-local` | `/tank` |
| `tank/recv/<peer>` | raw backups from `<peer>` | the peer's key, never loaded here | never |

LUKS stays under the root pool: it is what the FDE assertion and the
FIDO2 unlock ([fde.md](fde.md)) work on, and it hides what ZFS native
encryption leaves visible, such as dataset names and sizes. The ZFS
keys on `rpool/home` and `tank/local` exist for one reason: so a raw
send of them is ciphertext wherever it lands. Each key is a passphrase
in a root-only file on the LUKS-encrypted root, loaded at boot by
`core.zfs.unlock`, so the disk passphrase at boot is the only
interactive step. **Record each passphrase in a password manager**:
it is what makes a backup restorable after the machine that held the
file is gone. The install script and `core-zpool` print it once.

`rpool/home` is what makes homes sendable with no user involvement. A
user who wants to run their own sends on their own schedule can be
delegated `zfs allow -u <user> send,snapshot,hold,bookmark` on a child
dataset of `rpool/home`; the receiver side does not change.

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

## Creating the data pool

`core-zpool` is on every machine with `core.zfs.enable`. It lists the
disks (those with anything mounted or in an imported pool are shown
but cannot be chosen), takes the selection and the topology (single,
mirror, raidz1, raidz2), asks for `YES`, wipes the disks, creates
`tank` with the standard properties and `tank/local` with a fresh
passphrase, and prints the passphrase and the `core.zfs.*` lines to
add. With `--config /etc/nixos/configuration.nix` it adds those lines
itself.

```sh
sudo core-zpool --config /etc/nixos/configuration.nix
nixos-rebuild switch --sudo
```

The install script offers the same wizard before the first install,
for machines whose data disks are in from the start.

Compression on the pool is for `tank/local`; received raw datasets
carry their sender's blocks and ignore it.

## Receiving

```nix
core.zfs.enable = true;
core.zfs.pools = [ "tank" ];
core.zfs.unlock = [ "rpool/home" "tank/local" ];
core.backup.receive.enable = true;
core.backup.receive.from = [ "hawkeye" ];    # names from peers.nix
services.openssh.enable = true;
```

After the rebuild, `backup-receive-setup.service` creates `tank/recv`
and `tank/recv/<peer>` for every accepted peer and delegates the
receive permissions to `recv-<peer>`. It runs at every boot, so a peer
added to `from` later needs only a rebuild (`zfs allow` only adds; a
permission dropped from the module's list is removed by hand once
with `zfs unallow`).

`sanoid` prunes the received snapshots by
`core.backup.receive.retention` (60 daily, 24 monthly, 3 yearly by
default). It takes no snapshots of its own there and leaves snapshots
that are not sanoid-named alone, such as a manual `@backup-2026-10-21`.

## Sending

```nix
core.backup.send.datasets = {
  "rpool/home".to = [ "obelisk" ];
  "tank/local".to = [ "obelisk" "hawkeye" ];
};
```

One syncoid unit per dataset and peer runs on
`core.backup.send.interval` (daily): recursive, raw, received
unmounted, `--no-sync-snap` so it ships sanoid's snapshots, and
`--no-rollback` so it never attempts `receive -F`. `rpool/home` lands
at `tank/recv/<me>/home` on the receiver, `tank/local` at
`tank/recv/<me>/local`. The host key is the client identity, handed
to the sandboxed syncoid user with `LoadCredential=`.

A unit refuses a source whose `encryption` property is `off`: a raw
send of plaintext is plaintext, and the receiver's blindness must not
depend on remembering that.

sanoid snapshots the sent datasets by `core.backup.send.snapshots`
(24 hourly, 30 daily, 12 monthly, 1 yearly). Receivers keep their own,
longer history.

```sh
systemctl list-timers 'syncoid-*'
systemctl start syncoid-tank-local-obelisk     # send now
journalctl -u syncoid-tank-local-obelisk -e
```

## Sending by hand

For a machine that is not on nixos-core yet, or a one-off. As root;
the host key is the identity and the receiver has it in `peers.nix`.

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
tank/local@$SNAP` into the same destination.

## Alerts

```nix
core.alerts.command = ''
  ${pkgs.curl}/bin/curl -fsS -H "Title: $1" \
    -H "Authorization: Bearer $(cat /etc/alerts/ntfy-token)" \
    --data-binary @- https://ntfy.example.net/machines
'';
```

The command gets the title, prefixed with the hostname, as `$1` and
`$ALERT_TITLE`, and the body on stdin. Secrets go in a root-only file
the command reads, never in the option, which ends up in the
world-readable store. Unset, alerts go to the journal only. Try it:

```sh
echo "hello" | sudo alert-send "test"
```

What is reported:

- **A failed unit**, with its last 40 journal lines: the scrub, the
  key loading, the receiver's setup service, every syncoid unit, and
  sanoid. Other units join with `core.alerts.onFailure`.
- **Stale backups**, daily, on receivers: a peer whose newest received
  snapshot is older than `core.backup.receive.maxAge` (3 days), or
  that has sent nothing yet. A sender that silently stopped produces
  no failure anywhere else; this is what notices it.
- **Pool events**, from ZED: a vdev going DEGRADED, FAULTED, REMOVED
  or UNAVAIL; a scrub or resilver finishing with errors; data and
  deadman events, rate limited to one per pool per hour.

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
passphrase there. Nothing on the receiver is needed beyond the
datasets, which is why the passphrase must exist somewhere other than
the machine it protects.

```sh
# on the receiver, as root
zfs send -w -R tank/recv/<peer>/local@<snapshot> | ssh root@<machine> zfs receive -u tank/local
# on the machine
zfs load-key tank/local      # the recorded passphrase
zfs mount tank/local
```

## Not tested on a live pool yet

Everything here evaluates and builds; the first machine through each
path verifies it. Known uncertainties: `LoadCredential=` reaching the
sandboxed syncoid user (its `RootDirectory=` sandbox), and
`zed_rate_limit` under NixOS's ZED. If the first run of either
misbehaves, the fallback is a dedicated key in `/var/lib/syncoid` and
a zedlet without the rate limit.
