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
  zfs.nix            # core.zfs.enable — ZFS tools, hostId from the hostname, key loading, pool import, scrubs
templates/
  machine/           # scaffold for a new machine repo
docs/
  new-machine.md     # full walkthrough: machine repo -> install -> users
  fde.md             # disk-unlock management: passphrases, YubiKeys, token-only
  vpn.md             # VPN account setup and daily commands
  zfs.md             # the ZFS install layout, keys and core.zfs
scripts/
  nixos-install.sh   # disk partitioning (LUKS + ZFS root) + install for a new machine
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
- `core.zfs.enable` — ZFS with a hostname-derived hostId, key loading
  (`core.zfs.unlock`), pool import at boot (`core.zfs.pools`), scrubs;
  on in the template, since the install script puts the root on ZFS
  ([docs/zfs.md](docs/zfs.md)).

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
