# nixos-core

Shared NixOS library flake. This repo defines **no machines and no users** —
it exports reusable modules and a template for per-machine repos.

## The three-repo model

| Repo | Owns | Example |
|---|---|---|
| **nixos-core** (this repo) | Shared modules & options, machine template, install script | — |
| **One repo per machine** | Hostname, hardware config, `core.*` toggles, user *accounts* | [nixos-wisp](https://github.com/nullcopy/nixos-wisp) |
| **One repo per user** | That user's home environment via standalone home-manager | [nullcopy/dotfiles](https://github.com/nullcopy/dotfiles) |

Machine repos consume this repo as a flake input, so improvements flow out as
versioned updates (`nix flake update core` in the machine repo) — never as
git merges. Users manage their own environments from their own dotfiles
repos; the machine only declares that their accounts exist.

## Layout

```
flake.nix            # exports nixosModules.default and templates.machine
modules/
  default.nix        # entry point — machine flakes import this
  base.nix           # always-on baseline (nix, gc, net, resolved, base pkgs), all mkDefault
  desktop.nix        # core.desktop.enable — niri + greetd + portals + audio + bluetooth
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

(Dev shells are a user-space concern and live in each user's dotfiles repo,
e.g. `nix develop github:nullcopy/dotfiles#rust`.)

## Options

Everything opinionated is either overridable (opinionated values in
`base.nix` carry `lib.mkDefault`, so a machine config can override them
without `mkForce`; list options like `environment.systemPackages` merge) or
off until the machine enables it:

- `core.desktop.enable` — full graphical stack: niri, greetd/tuigreet, XDG
  portals, pipewire audio, bluetooth, power management, noctalia companion
  tools. Leave off for servers.
- `core.fde.*` — full-disk encryption is **mandatory**: the build fails if
  the initrd unlocks no LUKS volume (`core.fde.allowUnencrypted` is the
  discouraged escape hatch for throwaway VMs). Unlock methods are LUKS2
  keyslots — passphrases and FIDO2 tokens (YubiKeys) in any combination,
  including token-only — managed with the standard tools per
  [docs/fde.md](docs/fde.md). `core.fde.fido2.enable` turns on token
  unlock at boot; `core.fde.name` covers a non-default mapper name.
- `core.nymvpn.enable` — NymVPN daemon and CLI, machine-wide: one account
  per machine, stored daemon-side once by the admin; `nym-vpn-autoconnect`
  then brings the tunnel up at every boot as the default route for every
  user's traffic.
- `core.tailscale.enable` — tailscale daemon only. The admin connects by
  hand with `sudo tailscale up` and never with an exit node: only tailnet
  destinations use it, everything else goes via NymVPN.
- Localization (`time.timeZone`, `i18n.defaultLocale`) is per machine, set
  in each machine's `configuration.nix`, not here.

## Setting up a new machine

**Full from-scratch walkthrough: [docs/new-machine.md](docs/new-machine.md)**
— ISO download through per-user home setup, with a complete annotated
machine-config example, disk-unlock management (passphrases & YubiKeys), and
[nixos-wisp](https://github.com/nullcopy/nixos-wisp) as the real-world
reference. The short version:

1. Scaffold a repo for it:
   ```
   nix flake init -t github:nullcopy/nixos-core#machine
   ```
   Replace the `MYHOSTNAME`/`MYADMIN` placeholders, set the toggles, push it.
2. From the NixOS live ISO, download `scripts/nixos-install.sh`, edit the
   variables at the top (`DISK`, `MACHINE_REPO`, `HOSTNAME`, `ADMINUSER`),
   and run it as root. It partitions (GPT, EFI + LUKS2 btrfs), clones the
   machine repo to `/home/<admin>/.nixos`, generates
   `hardware-configuration.nix`, and runs `nixos-install`.
3. After first boot, each user clones their own dotfiles repo and applies it
   with standalone home-manager.

## Day to day

In a **machine repo** (not here):

```
sudo nixos-rebuild switch --flake ~/.nixos   # or wherever it's cloned
nix flake update core                        # pull nixos-core improvements
nix flake update                             # bump everything
```

In **this repo**: edit modules, commit, push. Machines pick the change up on
their next `nix flake update core`.

## Formatting

The repo ships a pre-commit hook that auto-formats `.nix` files with
`nixfmt` (the file lives in `templates/machine/.githooks/`; the root
`.githooks/pre-commit` is a symlink to it, so machine repos and this repo
share one copy). After cloning, point git at it:

```
git config core.hooksPath .githooks
```

Or format manually with `nix fmt`.
