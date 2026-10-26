# nixos-core

This repo is a shared NixOS library flake. It defines **no machines and no
users**. It exports reusable modules and a template for per-machine repos.

## The three-repo model

| Repo | Owns | Example |
|---|---|---|
| **nixos-core** (this repo) | Shared modules & options, machine template, install script | — |
| **One repo per machine** | Hostname, hardware config, `core.*` toggles, user *accounts* | `/etc/nixos` on that machine |
| **One repo per user** | That user's home environment via standalone home-manager | [nullcopy/dotfiles](https://github.com/nullcopy/dotfiles) |

Machine repos consume this repo as a flake input and pull updates with
`nix flake update core`. A machine repo is a local git repo on its
machine, created by the install script from the template; it has no
remote.

## Layout

```
flake.nix            # exports nixosModules.default and templates.machine
modules/
  default.nix        # entry point — machine flakes import this
  base.nix           # always-on baseline (nix, gc, memory guardrails, net, resolved, base pkgs), all mkDefault
  desktop.nix        # core.desktop.enable — full DE: niri+noctalia baseline, greetd, audio
  fde.nix            # mandatory-FDE assertion + core.fde.fido2 YubiKey boot unlock
  tailscale.nix      # core.tailscale.enable — daemon only; manual `sudo tailscale up`
  nymvpn.nix         # core.nymvpn.enable — packaged nym-vpnd/vpnc + polkit; no egress beyond the LAN until a manual `nym-vpnc connect`
  obscura.nix        # core.obscura.enable — obscura daemon/CLI from its flake; no egress beyond the LAN until a manual `obscura connect`
  zfs.nix            # core.zfs.enable — ZFS for data pools on attached drives: hostId, import, key loading, scrubs
  backup.nix         # core.backup.receive — accept raw ZFS replication from paired senders; the core-backup command
templates/
  machine/           # scaffold for a new machine repo
docs/
  new-machine.md     # full walkthrough: machine repo -> install -> users
  fde.md             # disk-unlock management: passphrases, YubiKeys, token-only
  vpn.md             # VPN account setup and daily commands
  zfs.md             # ZFS data pools: core.zfs and core-zpool
  backup.md          # ZFS-native backups between machines: design, pool layout, procedures
scripts/
  nixos-install.sh   # disk partitioning + install for a new machine
  zpool-wizard.sh    # `core-zpool`: create a data pool on attached drives (disk selection, topology, tank/encrypted)
  core-backup.sh     # `core-backup`: pair backup senders with a receiver (magic-wormhole), list, revoke
```

## Options

`base.nix` values carry `lib.mkDefault`; every other feature is off until
a machine enables it.

- `core.desktop.enable` — full desktop for every user (niri + Noctalia,
  greetd, pipewire, bluetooth).
- `core.fde.*` — FDE, mandatory via build assertion; `fido2.enable` adds
  YubiKey boot unlock ([docs/fde.md](docs/fde.md)).
- `core.nymvpn.enable` — machine-wide NymVPN as the default route, with
  no egress beyond the local network after boot until the admin runs
  `nym-vpnc connect` ([docs/vpn.md](docs/vpn.md)).
- `core.obscura.enable` — machine-wide Obscura VPN as the default route,
  with no egress beyond the local network after boot until the admin
  runs `obscura connect` ([docs/vpn.md](docs/vpn.md)). Exclusive with
  `core.nymvpn.enable`.
- `core.tailscale.enable` — tailscale daemon; the admin runs
  `sudo tailscale up`, tailnet traffic only ([docs/vpn.md](docs/vpn.md)).
- `core.zfs.enable` — ZFS for data pools on attached drives: a
  hostname-derived hostId, import at boot (`core.zfs.pools`), key
  loading (`core.zfs.unlock`), scrubs ([docs/zfs.md](docs/zfs.md)).
- `core.backup.receive.enable` — accept raw ZFS replication from
  senders paired with `core-backup invite`, stored encrypted with keys
  this machine never has ([docs/backup.md](docs/backup.md)).

## New machine setup

The full walkthrough is in [docs/new-machine.md](docs/new-machine.md).
The summary is:

1. Start the NixOS live ISO. Download `scripts/nixos-install.sh` and
   run it as root. The script asks for the disk, the hostname, the
   admin user and whether to enable ssh, partitions the disk, creates
   the machine repo from the template in `/etc/nixos`, owned by the
   admin, opens a shell to set the `core.*` toggles, and installs the
   system.
2. After the first boot, each user clones their own dotfiles repo. Each
   user applies it with standalone home-manager.

## Day to day

Use these commands in a **machine repo**:

```
nixos-rebuild switch --sudo                  # apply config edits
nix flake update core                        # pull nixos-core updates, then rebuild
nix flake update                             # bump everything, then rebuild
```

## Working on this repo

`nix develop` (or direnv with `use flake` in `.envrc`) gives a shell with
nil, nixfmt, prettier and shellcheck. The pre-commit hook in `.githooks`
formats staged `.nix` files with that nixfmt.

## License

This project is licensed under the [GNU Affero General Public License v3.0 or later](LICENSE) (`AGPL-3.0-or-later`).
