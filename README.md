# nixos-core

This repo is a shared NixOS library flake. It defines **no machines and no
users**. It exports reusable modules and a template for per-machine repos.

## The three-repo model

| Repo | Owns | Example |
|---|---|---|
| **nixos-core** (this repo) | Shared modules & options, machine template, install script | — |
| **One repo per machine** | Hostname, hardware config, `core.*` toggles, user *accounts* | [nixos-wisp](https://github.com/nullcopy/nixos-wisp) |
| **One repo per user** | That user's home environment via standalone home-manager | [nullcopy/dotfiles](https://github.com/nullcopy/dotfiles) |

Machine repos consume this repo as a flake input and pull updates with
`nix flake update core`.

## Layout

```
flake.nix            # exports nixosModules.default and templates.machine
modules/
  default.nix        # entry point — machine flakes import this
  base.nix           # always-on baseline (nix, gc, net, resolved, base pkgs), all mkDefault
  desktop.nix        # core.desktop.enable — full DE: niri+noctalia baseline, greetd, audio
  fde.nix            # mandatory-FDE assertion + core.fde.fido2 YubiKey boot unlock
  tailscale.nix      # core.tailscale.enable — daemon only; manual `sudo tailscale up`
  nymvpn.nix         # core.nymvpn.enable — packaged nym-vpnd/vpnc + polkit + boot autoconnect
templates/
  machine/           # scaffold for a new machine repo
docs/
  new-machine.md     # full walkthrough: machine repo -> install -> users
  fde.md             # disk-unlock management: passphrases, YubiKeys, token-only
scripts/
  nixos-install.sh   # disk partitioning + install for a new machine
```

## Options

`base.nix` values carry `lib.mkDefault`; every other feature is off until
a machine enables it.

- `core.desktop.enable` — full desktop for every user (niri + Noctalia,
  greetd, pipewire, bluetooth).
- `core.fde.*` — FDE, mandatory via build assertion; `fido2.enable` adds
  YubiKey boot unlock ([docs/fde.md](docs/fde.md)).
- `core.nymvpn.enable` — machine-wide NymVPN, connects at boot as the
  default route.
- `core.tailscale.enable` — tailscale daemon; the admin runs
  `sudo tailscale up`, tailnet traffic only.

## New machine setup

The full walkthrough is in [docs/new-machine.md](docs/new-machine.md).
The summary is:

1. Scaffold a repo for the machine:
   ```
   nix flake init -t github:nullcopy/nixos-core#machine
   ```
   Replace the `MYHOSTNAME` and `MYADMIN` placeholders. Set the toggles.
   Push the repo.
2. Start the NixOS live ISO. Download `scripts/nixos-install.sh`. Edit
   the variables at the top (`DISK`, `MACHINE_REPO`, `HOSTNAME`,
   `ADMINUSER`). Run the script as root. The script partitions the disk,
   clones your repo, and installs the system.
3. After the first boot, each user clones their own dotfiles repo. Each
   user applies it with standalone home-manager.

## Day to day

Use these commands in a **machine repo**:

```
sudo nixos-rebuild switch --flake ~/.nixos   # apply config edits
nix flake update core                        # pull nixos-core updates, then rebuild
nix flake update                             # bump everything, then rebuild
```
