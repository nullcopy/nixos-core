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
  cannot take its history on the receiver with it. It can send its own
  dataset back — raw streams of encrypted datasets, nothing else —
  which is what a restore pulls ([Restoring onto a new
  machine](#restoring-onto-a-new-machine)).

The modules, all in [modules/](../modules):

| Option | Module | Does |
|---|---|---|
| `core.zfs` | zfs.nix | ZFS itself: hostId, pool import, key loading, scrubs, pool-event alerts, the `mkzpool` wizard |
| `core.backup.receive` | backup.nix | accept raw replication from paired senders into `tank/recv/<name>`; the `core-backup` command |
| `core.backup.send` | backup-send.nix | push raw replication of this machine's datasets to peers, with the machine's backup key |
| `core.alerts` | alerts.nix | where failed units, stale backups and pool events are reported |

## Pool layout

The same names on every machine, so modules and procedures carry
over. `mkzpool` creates the pool ([zfs.md](zfs.md)); the root
stays on btrfs and is not part of this.

| Dataset | Holds | Encryption | Mounted |
|---|---|---|---|
| `tank` | the data pool, on the data disks | – | no |
| `tank/encrypted` | this machine's own data; what replication covers | the ZFS encryption root, key in `/etc/zfs/keys/tank-encrypted` | `/data` |
| `tank/recv/<peer>` | raw backups from `<peer>` | the peer's key, never loaded here | never |

The ZFS key on `tank/encrypted` exists for one reason: so a raw send
of it is ciphertext wherever it lands. It is a passphrase in a
root-only file on the LUKS-encrypted root, loaded at boot by
`core.zfs.unlock`, so the disk passphrase at boot is the only
interactive step. **Record the passphrase in a password manager**: it
is what makes a backup restorable after the machine that held the
file is gone. `mkzpool` prints it once.

A user who wants to run their own sends on their own schedule can be
delegated `zfs allow -u <user> send,snapshot,hold,bookmark` on a child
dataset of `tank/encrypted`; the receiver side does not change.

## Pairing

Which senders a receiver accepts is state on the receiver, managed
with `core-backup`; no repository changes when a machine joins. Each
sender has a backup key, `/var/lib/backup/key`, which its sends log
in with. `core.backup.send` makes it at first boot. It is separate
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

The account has a login shell: syncoid needs one on this end, and
`restrict` does not stop it running commands, so an accepted sender —
or anyone holding its key — can run commands as `recv-<name>`. The
delegation keeps it away from other senders' data and from anything
owned by root, but it is a shell: accept only machines you control.
`core.backup.receive` also defaults `services.openssh` to key-only and
leaves :22 closed on the firewall, opened on the tailnet interface
when `core.tailscale` is on; open the port where your senders reach
the machine if they use another path.

The delegation lets the account send as well as receive:
`send:encrypted` returns that account its own dataset as raw streams
of encrypted datasets and nothing more. Pairing a machine again after
a reinstall is therefore all a restore needs from the receiver
([Restoring onto a new machine](#restoring-onto-a-new-machine)).

```sh
sudo core-backup list              # name, quota, space used, newest snapshot
sudo core-backup revoke hawkeye    # stops its sends; tank/recv/hawkeye stays
```

The sender trusts the receiver's host key on first use and pins it in
`/var/lib/syncoid/known_hosts`. Peers are reached over the tailnet,
whose WireGuard identities already authenticate the address.

## Receiving

```nix
core.zfs.enable = true;
core.zfs.pools = [ "tank" ];
core.zfs.unlock = [ "tank/encrypted" ];
core.backup.receive.enable = true;
services.openssh.enable = true;
```

Create the pool with `mkzpool` ([zfs.md](zfs.md)), then pair
senders. At every boot, `backup-receive-setup.service` recreates
`tank/recv` and, for each accepted sender, its key file, dataset,
delegation (reset to exactly the list in `core-backup`) and quota.
The quota is a ZFS `quota` on the sender's dataset, which the sender
cannot change; without one, a runaway or compromised sender fills the
pool.

`sanoid` prunes the received snapshots by
`core.backup.receive.retention` (60 daily, 24 monthly, 3 yearly by
default). The NixOS module runs it as its own user with `snapshot`,
`mount` and `destroy` delegated on `tank/recv` for the run; it takes
no snapshots of its own there and leaves snapshots that are not
sanoid-named alone, such as a manual `@backup-2026-10-21`.

## Sending

```nix
core.backup.send.datasets = {
  "tank/encrypted".to = [ "obelisk" "hawkeye" ];
};
```

The first boot with this makes the backup key; pair it with each
receiver (see Pairing). The names in `to` are hostnames or addresses.

One syncoid unit per dataset and peer runs on
`core.backup.send.interval` (daily): recursive, raw, received
unmounted, uncompressed (ciphertext does not compress),
`--no-sync-snap` so it ships sanoid's snapshots, and `--no-rollback`
so it never attempts `receive -F`. `tank/encrypted` lands at
`tank/recv/<me>/encrypted` on the receiver. A nested dataset needs its
parent sent to the same peers; the module checks. The backup key is handed to the
sandboxed syncoid user with `LoadCredential=`.

The sender's zfs delegation is `send:encrypted`: the kernel allows raw
streams of encrypted datasets and nothing else, so a dataset without
encryption cannot be sent even by mistake. A pre-check gives a
readable error for the same case. A raw send of plaintext would be
plaintext, and the receiver's blindness must not depend on remembering
that.

sanoid snapshots the sent datasets by `core.backup.send.snapshots`
(24 hourly, 30 daily, 12 monthly, 1 yearly). Receivers keep their own,
longer history.

```sh
systemctl list-timers 'syncoid-*'
systemctl start syncoid-tank-encrypted-obelisk     # send now
journalctl -u syncoid-tank-encrypted-obelisk -e
```

### When sends stop working

Two conditions need root on the receiver, by design: the sending
account cannot destroy anything there, and both fixes destroy.

- **A partial receive whose source snapshot is gone.** An interrupted
  send leaves a resumable partial receive. syncoid resumes it on the
  next run, unless the snapshot it was sending has since been pruned
  on the sender (an hourly lives 24 hours); then every run fails with
  `receive -A` denied. On the receiver:
  `sudo zfs receive -A tank/recv/<peer>/<dataset>` discards the
  partial state, and the next run sends from the last common snapshot.
- **The receiver's newest snapshot no longer exists on the sender.**
  An incremental must start from the receiver's newest snapshot. The
  receiver prunes hourlies at once (its `hourly` retention is 0), so
  its newest is normally a daily, which the sender keeps 30 days
  (`core.backup.send.snapshots.daily`). After a longer outage every
  run fails with "most recent snapshot does not match incremental
  source". Either raise `daily` on the sender beforehand, or on the
  receiver `zfs destroy` the receiver-only snapshots newer than the
  last common one; the alert names the unit, its journal names the
  snapshots.

Both show up as a failed unit through `core.alerts`.

## Sending by hand

For a machine that is not on nixos-core yet, or a one-off. As root.
The identity is a backup key, paired with the receiver as above:

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
tank/encrypted@$SNAP` into the same destination.

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
  key loading, the receiver's setup service, the backup key creation,
  every syncoid unit, and sanoid. Other units join with
  `core.alerts.onFailure` (names of units that exist).
- **Stale backups**, daily, on receivers: a peer whose newest received
  snapshot is older than `core.backup.receive.maxAge` (3 days), or
  that has sent nothing yet. A sender that silently stopped produces
  no failure anywhere else; this is what notices it.
- **Unblind data**, daily, on receivers: a received dataset with no
  encryption root of its own — a sender sent without `-w` — or whose
  key shows as available here. nixos-core senders cannot send
  anything but raw (`send:encrypted`); a one-off sender outside it
  has no such guard, and this is what catches it.
- **Pool events**, from ZED: a vdev going DEGRADED, FAULTED, REMOVED
  or UNAVAIL; a scrub or resilver finishing with errors; data and
  deadman events, rate limited to one per pool per hour.

## Verifying a receiver is blind

On the receiver, after the first send:

```sh
sudo zfs get -r encryption,keystatus,encryptionroot,mounted tank/recv
sudo zfs mount tank/recv/<peer>/encrypted     # must fail: key not loaded
```

`keystatus` is `unavailable` on every received dataset. Never run
`zfs load-key` on a received dataset: the raw stream carries the
sender's wrapped key, so the sender's passphrase would unlock it here
too. Blindness is a rule on the receiver, not an impossibility.

The account's `send:encrypted` does not weaken this: the most it can
return is raw streams of encrypted datasets, which are ciphertext
here and unlock only where the key is.

The daily stale check enforces what it can of the rule: a dataset
under a peer whose `encryptionroot` is not itself arrived from a
stream that was not raw, and a `keystatus` of `available` means its
key was loaded here. Either alerts.

## Restoring onto a new machine

A backup is data, not a system: install NixOS and this flake on the
new machine as usual ([new-machine.md](new-machine.md)), then pair it
with the receiver and pull the dataset back. The receiver raw-sends it
without ever holding the key — the stream stays ciphertext end to end
— so a restore needs two things: the receiver's copy, and the key,
kept somewhere other than the machine it protects.

If instead the pool's disks survived and only the root was
reinstalled, there is nothing to transfer: recreate the key file and
load it ([zfs.md](zfs.md), Reinstalling).

### On the receiver

Pair the machine being restored under the name the data arrived as.
`tank/recv/<name>` is where the backup lives, so a machine keeping its
hostname is the same name, and a replacement machine is the old one:

```sh
sudo core-backup revoke hawkeye    # only while the old key is accepted
sudo core-backup invite hawkeye
```

`revoke` keeps the dataset — it drops the account and its key — and
`invite` prints a code for the next step. A machine that still holds
the backup key it sent with can skip both and keep its pairing.

### On the new machine

Configuration first, so the restored dataset is imported and unlocked
at boot:

```nix
core.zfs.enable = true;
core.zfs.pools = [ "tank" ];
core.zfs.unlock = [ "tank/encrypted" ];
services.openssh.enable = true;
```

Create the pool without an encrypted dataset:

```sh
sudo mkzpool --no-encrypted
```

Without `--no-encrypted`, `mkzpool` creates its own `tank/encrypted`
with a fresh passphrase, and the restore has nowhere to land. The
restore brings back the original encryption root, its key location and
its mountpoint. `mkzpool` writes the `core.zfs.pools` line; add the
`core.zfs.unlock` line yourself for the dataset being restored.

The key file goes where the backup expects it. A nixos-core sender
keeps it at `/etc/zfs/keys/<pool>-encrypted` ([zfs.md](zfs.md),
Reinstalling); a sender that keeps a key file elsewhere records that
path in the stream, and the received dataset shows it as
`keylocation`. Recreate the path from your copy, or point at the copy
directly when loading the key:

```sh
sudo install -d -m 700 /etc/zfs/keys
sudo install -m 600 /path/to/saved/tank-encrypted /etc/zfs/keys/tank-encrypted
# or: sudo zfs load-key -L file:///path/to/saved/tank-encrypted tank/encrypted
```

Then `nixos-rebuild switch --sudo`.

The pull logs in as the paired account, so the new machine needs a
backup key of its own — the same pairing a sender does
([Pairing](#pairing)), as root here:

```sh
install -d -m 755 /var/lib/backup
ssh-keygen -t ed25519 -N "" -C "backup@$(hostname)" -f /var/lib/backup/key
wormhole ssh accept -F /var/lib/backup <code>
```

(A machine running `core.backup.send` already made that key at first
boot; `core-backup join <code>` then replaces the last two lines.)

Then, still as root, list what the receiver holds and pull the
snapshot:

```sh
ssh -i /var/lib/backup/key recv-hawkeye@obelisk \
  zfs list -t snapshot -o name tank/recv/hawkeye/encrypted

ssh -i /var/lib/backup/key recv-hawkeye@obelisk \
  zfs send -w -R tank/recv/hawkeye/encrypted@<snapshot> | \
  zfs receive -u tank/encrypted
```

The account's delegation includes `send:encrypted`, so this needs no
sudo and no `zfs allow` on the receiver, and the most it can return is
raw streams of encrypted datasets. Run it in `tmux`; an interrupted
receive resumes like any other ([Sending by hand](#sending-by-hand)).

Once the data is back:

```sh
sudo zfs load-key -r tank/encrypted      # the parent and every child
sudo zfs mount -a
sudo zfs get keystatus tank/encrypted    # available
```

The restored dataset carries the sender's mountpoint; set it before
mounting if this machine wants another (`zfs set mountpoint=/data
tank/encrypted`, children inherit).

Children sent with `--recursive` arrive as their own encryption roots;
`zfs change-key -i` on each re-inherits the parent's key, so later key
changes on the parent propagate.

Then check it is the data you think it is. A checksum manifest made on
the source before it was wiped proves the files:

```sh
sudo sh -c 'cd /data && sha256sum -c /path/to/manifest.sha256'
```

A scrub proves every block against the checksums the sender recorded,
reading only this machine's disks:

```sh
sudo zpool scrub tank && sudo zpool status -v tank
```

One thing that bites: a machine that already has a `tank/encrypted`
refuses the receive. `--no-encrypted` is the way to avoid it;
otherwise restore under another name and `zfs rename` it into place.

## Things to know

- **Reinstalling a machine that has a `tank`.** The key file
  `/etc/zfs/keys/tank-encrypted` was on the wiped root. Recreate it from
  the password manager ([zfs.md](zfs.md), Reinstalling); until then
  `zfs-import-tank` fails on the key (and alerts), `tank/encrypted`
  stays unmounted, and `/data` is an empty directory on the root.
- **Reinstalling a receiver** changes its host key and loses its
  accepted senders. Each sender's syncoid unit then fails on the host
  key (and alerts); remove the old one with `ssh-keygen -R <receiver>
  -f /var/lib/syncoid/known_hosts` and pair the senders again. Their
  datasets under `tank/recv` survive and continue.
- **Renaming a machine** changes its hostId. The pool import fails
  ("last accessed by another system") until a one-time
  `zpool import -f tank`, or the old value is pinned as
  `networking.hostId`. The boot itself is unaffected.
- **Re-pairing a revoked name.** `core-backup revoke` leaves
  `tank/recv/<name>` in place, and a fresh pairing of the same name
  cannot reuse it: the receiver's snapshots are not on the sender, so
  every incremental fails with a history mismatch. If the old backups
  are not wanted, `sudo zfs destroy -r tank/recv/<name>` before
  accepting the name again.
- **Nothing here has run on a live pool yet.** Everything evaluates
  and builds, and an independent review checked the delegation set,
  the syncoid command path, the credential hand-off into the sandbox,
  the zedlet registration and the wizard's passphrase handling
  against the sources. The first machine through each path is still
  the real test; the review's list for that run: delegation and
  encryption roots on the receiver after the first send, the
  known_hosts match on the tailnet name, `journalctl -u zfs-zed`
  showing the zedlet registered, and one deliberately interrupted
  send resuming.
