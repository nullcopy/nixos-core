# Updates

How a machine takes updates, and the background fetch that makes them
cheap. Every command runs on the machine, in the machine repo
(`/etc/nixos`), as the admin user.

## Updating

```sh
nix flake update                 # bump every input (core, and nixpkgs through it)
nixos-rebuild switch --sudo
```

`nix flake update core` bumps only nixos-core; the machine's nixpkgs
follows core's, so that moves nixpkgs too. To see what a switch would
download before running it:

```sh
nix flake update && nixos-rebuild build --dry-run
```

## Background fetch (`core.updates.fetch`)

An update downloads a large part of the system closure. The
`nixos-fetch` timer does that download ahead of time: once a day it
builds the system generation that the newest inputs give, without
switching to it. When you update, the inputs have moved by a day at
most, and nearly every path the switch needs is already in the store.

It is off until a machine enables it, like every other nixos-core
feature:

```nix
core.updates.fetch.enable = true;
```

The service runs as the owner of the machine repo (`core.updates.fetch.user`, by default the
machine's only `wheel` user) and does three things
(`modules/updates.nix`):

```sh
nix flake update --flake /etc/nixos --output-lock-file /run/nixos-fetch/flake.lock
nix build '/etc/nixos#nixosConfigurations."<host>".config.system.build.toplevel' \
  --reference-lock-file /run/nixos-fetch/flake.lock --no-write-lock-file \
  --out-link /var/lib/nixos-fetch/system
nix flake archive --json ... | nix build <every input source> --out-link /var/lib/nixos-fetch/inputs.<time>/input
```

- The updated lock goes to `/run/nixos-fetch`, not to the repo. The
  fetch never touches `flake.lock` or the working tree, and it never
  switches: what runs on the machine changes only when you switch.
- The out-links in `/var/lib/nixos-fetch` are GC roots, so the fetched
  generation and the source tree of every input survive `nix.gc` until
  the next fetch replaces them.
- The build sees the working tree as it is, as `nixos-rebuild` would:
  uncommitted edits to tracked files are included, untracked files are
  not. A new module that is imported but not yet `git add`ed fails the
  fetch as it fails the switch.
- Inputs that need credentials (a private repo, a `git+ssh` URL) are
  fetched with that user's SSH keys and `~/.config/nix/nix.conf`
  (`access-tokens`). Nothing interactive is available: no agent, no
  passphrase prompt. A key that needs one fails the fetch.
- Builds go through nix-daemon, under base.nix's memory cap, with at
  most `maxJobs` derivations at once and `cores` cores each (2 and 8 by
  default). The evaluation runs in the service itself, capped at 30% of
  RAM (`systemd.services.nixos-fetch.serviceConfig.MemoryMax` changes
  that). The service runs at the lowest CPU and IO priority. Almost
  everything comes from the binary cache; the caps are for what does
  not.
- The run is skipped on battery power. A run missed while the machine
  was off happens at the next boot.
- An interrupted fetch keeps every path it finished; the next run
  downloads the rest. The previous run's inputs stay rooted until a run
  has rooted the new ones.

When `nix flake update` fails, most likely on the network, the run is
tried again after 30 minutes, twice. A failed evaluation or build is
not retried: it would fail the same way until the repo changes, and the
next day's run tries again. systemd allows the service three starts in
six hours, manual ones included, and refuses a fourth with
`start-limit-hit`; `reset-failed` clears that count.

```sh
systemctl list-timers nixos-fetch
journalctl -u nixos-fetch -e
sudo systemctl start nixos-fetch            # fetch now
sudo systemctl reset-failed nixos-fetch     # after start-limit-hit
```

### Options

Set these in the machine's `configuration.nix`.

| Option | Default | |
|---|---|---|
| `core.updates.fetch.enable` | `false` | `true` installs the timer and service |
| `core.updates.fetch.flake` | `"/etc/nixos"` | absolute path of the machine repo to update and build |
| `core.updates.fetch.user` | the only `wheel` user, else `root` | who the fetch runs as: the repo's owner |
| `core.updates.fetch.configName` | `networking.hostName` | the `nixosConfigurations` attribute to build; set it when that is not named after the hostname |
| `core.updates.fetch.dates` | `"daily"` | systemd `OnCalendar` expression |
| `core.updates.fetch.maxJobs` | `2` | derivations built at once |
| `core.updates.fetch.cores` | `8` | cores per derivation |

### Turning it off

A machine on a metered or slow link, or one updated rarely, may not
want a daily download of a generation it will not switch to. Set
`core.updates.fetch.enable = false` (or remove the line); after the
next switch the timer is gone. `/var/lib/nixos-fetch` stays
and keeps the last fetch rooted; remove it to let `nix.gc` collect
that:

```sh
sudo rm -rf /var/lib/nixos-fetch
```

### Home environments

The fetch covers the system only. A user's home-manager generation is
built from that user's dotfiles, with its own nixpkgs, and needs its
own fetch; [nullcopy/dotfiles](https://github.com/nullcopy/dotfiles)
has one, the `home-manager-fetch` user timer.
