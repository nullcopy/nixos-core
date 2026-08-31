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
git merges.

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

Everything opinionated is either overridable (opinionated values in
`base.nix` carry `lib.mkDefault`, so a machine config can override them
without `mkForce`; list options like `environment.systemPackages` merge) or
off until the machine enables it:

- `core.desktop.enable` — full DE for every user (niri + Noctalia,
  greetd session menu, pipewire, bluetooth). Off for servers.
- `core.fde.*` — FDE is mandatory (build assertion); `fido2.enable` adds
  YubiKey unlock at boot. See [docs/fde.md](docs/fde.md).
- `core.nymvpn.enable` — machine-wide NymVPN; autoconnects at boot as the
  default route.
- `core.tailscale.enable` — tailscale daemon only; the admin runs
  `sudo tailscale up` by hand, never with an exit node.

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
   and run it as root. It partitions the disk, clones your repo, and
   installs.
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
