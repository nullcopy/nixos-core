# Setting up a new machine — from scratch

End-to-end walkthrough: from nothing but hardware and this repo to a fully
configured NixOS machine with per-user home environments. Generic NixOS
steps (downloading the ISO, making a USB stick) link to the official docs;
everything specific to this setup is spelled out here.

## How the pieces fit together

```
github:nullcopy/nixos-core          <- shared library (this repo)
        ^ flake input
github:nullcopy/nixos-<hostname>    <- the machine's own repo (one per machine)
                                       hostname, hardware, core.* toggles, accounts

github:<user>/dotfiles              <- each user's home environment,
                                       applied with standalone home-manager
```

- A machine repo is ~50 lines of config plus the generated hardware config
  — [nixos-wisp](https://github.com/nullcopy/nixos-wisp) is a complete
  real example.
- Users apply their homes with standalone
  [home-manager](https://github.com/nix-community/home-manager) (step 7);
  [nullcopy/dotfiles](https://github.com/nullcopy/dotfiles) is the
  reference layout.

## What you need

- The **target machine** — the one getting NixOS — and a USB stick
  (>= 2 GB) you can erase.
- A **working computer** — any OS, used to prepare the repo and write the
  USB stick. (Nix installed on it helps but isn't required.)
- A GitHub (or any git host) account to hold the machine repo.

Each step below says which of the two machines it runs on.

## 1. Create the machine's flake repo

**On the working computer.**

Pick a hostname (lowercase, e.g. `fern`). If the working computer has nix:

```sh
mkdir nixos-fern && cd nixos-fern
nix flake init -t github:nullcopy/nixos-core#machine
git init
```

If it doesn't, clone this repo and copy the template by hand:

```sh
git clone https://github.com/nullcopy/nixos-core
mkdir nixos-fern
cp -r nixos-core/templates/machine/. nixos-fern/ && cd nixos-fern && git init
```

(The trailing `/.` matters — it also copies the hidden `.githooks/`
formatting hook.)

Either way you now have `flake.nix`, `configuration.nix`,
`hardware-configuration.nix` (a placeholder the installer replaces), a
README, and `.githooks/`. Edit the first two:

### flake.nix

Replace `MYHOSTNAME` with your hostname. The result should look like:

```nix
{
  description = "NixOS configuration for fern";

  inputs = {
    core.url = "github:nullcopy/nixos-core";
    nixpkgs.follows = "core/nixpkgs";
  };

  outputs = { self, core, nixpkgs, ... }: {
    # The attribute name must match networking.hostName, so
    # `sudo nixos-rebuild switch --flake ~/.nixos` finds it automatically.
    nixosConfigurations.fern = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        core.nixosModules.default
        ./hardware-configuration.nix
        ./configuration.nix
      ];
    };
  };
}
```

That's the whole trick: `core.nixosModules.default` pulls in the shared
baseline, and everything below is this machine's personality.

### configuration.nix

Replace `MYHOSTNAME`/`MYADMIN` and set the toggles. A complete headless
server example:

```nix
{ config, lib, pkgs, ... }:

{
  networking.hostName = "fern";     # must match the flake.nix attribute

  ## Localization
  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";

  ## What this machine gets from nixos-core (all default to off):
  core.desktop.enable = false;      # niri + greetd + audio + Wayland plumbing
  core.nymvpn.enable = true;        # NymVPN: machine-wide tunnel at boot — see step 6
  core.tailscale.enable = true;     # tailscale daemon, manual `sudo tailscale up` — see step 6
  # core.fde.fido2.enable = true;   # YubiKey disk unlock — see step 5

  ## Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  ## Accounts (homes come from each user's own repo — step 7)
  users.users.alice = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "networkmanager" ];   # wheel = sudo
  };
  users.users.bob = {
    isNormalUser = true;
    shell = pkgs.zsh;
  };

  ## Anything machine-specific goes here too:
  # environment.systemPackages = with pkgs; [ htop ];
  # services.openssh.enable = true;

  ## First NixOS version installed on this machine. Never bump on an
  ## existing install.
  system.stateVersion = "25.11";
}
```

For a desktop/laptop, flip `core.desktop.enable = true` and compare with
[nixos-wisp's configuration.nix](https://github.com/nullcopy/nixos-wisp/blob/main/configuration.nix),
which also shows hardware quirks (udev rules, kernel modules, fwupd) and
the FIDO2 options in real use.

Available `core.*` options (see [modules/](../modules) for the source):

| Option | What it enables |
|---|---|
| `core.desktop.enable` | A complete desktop environment for every user: niri + Noctalia with a system-wide default config (`/etc/niri/config.kdl`), greetd/tuigreet with a session menu (niri or a plain shell), XDG portals, pipewire, bluetooth, power management |
| `core.fde.*` | FDE is mandatory (build-time assertion); `fido2.enable` for YubiKey unlock at boot; key management via standard tools (step 5, [docs/fde.md](fde.md)) |
| `core.tailscale.enable` | tailscale daemon only; the admin runs `sudo tailscale up` / `down` by hand, never with an exit node (step 6) |
| `core.nymvpn.enable` | NymVPN daemon and CLI; `core.nymvpn.autoconnect` (default on) brings the machine-wide tunnel up at boot (step 6) |

Values from `base.nix` carry `lib.mkDefault`, so overriding them here
just works.

### Push it

```sh
git add -A && git commit -m "Initial config for fern"
git remote add origin git@github.com:<you>/nixos-fern.git
git push -u origin main
```

A public repo makes install day simplest (the installer clones over
plain https). It should contain no secrets either way; if you keep it
private, you'll need credentials in the live environment.

## 2. Boot the NixOS installer

**On the working computer, then the target machine.**

Follow the official manual's
["Installation" chapter](https://nixos.org/manual/nixos/stable/#sec-installation):
download an ISO, write it to the USB stick, boot the target machine from
it, and bring networking up (confirm with `ping github.com`). **Stop before
its "Partitioning and formatting" section** — disk setup here is step 3's
script.

## 3. Run the install script

**On the target machine, in the live environment you just booted.**

> **What it assumes:** one whole disk, wiped, as GPT with a 1 GB EFI
> partition + a LUKS2-encrypted btrfs root (subvolumes `@`, `@home`, `@nix`,
> `@log`, `@snapshots`). If you need a different layout, partition manually
> following the [official installation manual](https://nixos.org/manual/nixos/stable/#sec-installation)
> instead, then rejoin this guide at the `nixos-generate-config` step —
> clone your machine repo, generate `hardware-configuration.nix` into it,
> and run `nixos-install --flake`.

In the live environment:

```sh
curl -O https://raw.githubusercontent.com/nullcopy/nixos-core/main/scripts/nixos-install.sh
vim nixos-install.sh    # set the four variables at the top:
                        #   DISK         e.g. /dev/nvme0n1 — check with lsblk!
                        #   MACHINE_REPO your repo's https URL
                        #   HOSTNAME     e.g. fern
                        #   ADMINUSER    the wheel user, e.g. alice
sudo bash nixos-install.sh
```

The script will:

1. Confirm with `YES` (all capitals), then **erase the disk**, partition it, and prompt for the
   **disk passphrase** — this unlocks the machine at every boot, so pick it
   deliberately.
2. Clone `MACHINE_REPO` to `/mnt/home/<ADMINUSER>/.nixos`, generate the
   real `hardware-configuration.nix` into it, create `flake.lock` (pinning
   nixos-core + nixpkgs for this machine), and commit both (as
   `<ADMINUSER>`; the live ISO has no git identity of its own). It also
   activates the repo's nixfmt pre-commit hook.
3. Print sanity checks (`ok`/`WARNING`) for the three mistakes that
   otherwise fail late inside `nixos-install`: `configuration.nix` sets
   `networking.hostName = "<HOSTNAME>"`, `flake.nix` defines
   `nixosConfigurations.<HOSTNAME>`, and `users.users.<ADMINUSER>` exists.
   Then ask **"Open a shell to review or edit? [y/N]"** — say `y` to get a
   shell inside the repo (fix any warnings; anything you edit here can be
   committed at first boot, step 4; type `exit` to return), or `N` to
   skip. Finally it asks for a second `YES` to proceed with
   `nixos-install`.
4. Run `nixos-install` (this builds/downloads the whole system — expect a
   while on first install), prompt for `ADMINUSER`'s login password, hand
   the repo's ownership to `ADMINUSER`, and unmount.

Remove the install media and reboot. You'll be asked for the disk
passphrase, then land on a login prompt (or the greeter, if the desktop is
enabled — press **F2** there to pick between the niri session and a plain
**Shell** session; the choice is remembered per user).

**If the script fails or you abort partway, just run it again from the
top.** It's a from-scratch wipe every time (nothing worth keeping exists on
the disk yet), and it first cleans up the previous attempt's mounts and
LUKS mapping. You'll re-enter the disk passphrase. If it died *after* the
clone step, you can instead finish by hand — the disk is still mounted at
`/mnt`:

```sh
nixos-install --flake "path:/mnt/home/<ADMINUSER>/.nixos#<HOSTNAME>" --no-root-password
nixos-enter --root /mnt -- passwd <ADMINUSER>
nixos-enter --root /mnt -- chown -R <ADMINUSER>:users /home/<ADMINUSER>
umount -R /mnt && cryptsetup close cryptroot
```

## 4. First boot

**On the target machine, now running its installed system.**

Log in as the admin user. The machine repo is at `~/.nixos`, owned by you —
normal git, no sudo needed for anything but the rebuild itself:

```sh
cd ~/.nixos
git push                              # the installer's hardware-config + flake.lock commit
sudo nixos-rebuild switch --flake ~/.nixos   # should be a no-op right now
```

(If you edited anything in the installer's review shell, `git add -A &&
git commit` that first.)

(The nixfmt pre-commit hook is already active — the installer ran
`git config core.hooksPath .githooks`. On any *other* clone of the repo,
run that once yourself.)

Committing `flake.lock` matters: it's what makes nixos-core updates
deliberate (`nix flake update core`) instead of whatever the remote
happens to be on the next rebuild.

If other users were declared, set their initial passwords so they can log
in: `sudo passwd bob`.

There is no root password and none is needed: the root account is locked
(`base.nix` declares it, and the installer never sets one). Use `sudo` for
admin work, `sudo -i` when you really need a root shell.

**About `~/.nixos` itself** — three facts worth knowing:

- *The running system does not depend on it.* `nixos-rebuild` copies the
  repo into the store; afterwards only store paths are referenced. Delete
  the checkout and the machine still boots — just clone again before the
  next rebuild (push first).
- *Other users can't read it, and don't need to.* Homes are `0700`;
  `nixos-rebuild` reads it as root via sudo. Another admin clones their
  own copy.
- *If root's git complains about "dubious ownership"* when rebuilding
  from a repo owned by you, that's git's safety check, not a real
  problem: `sudo git config --global --add safe.directory ~/.nixos` once.

## 5. Disk unlock methods (passphrases & YubiKeys)

**On the target machine, as the admin user.**

FDE is mandatory: the build fails without a LUKS volume in the initrd
(the installer always creates one; a manual layout must too). How it
unlocks is up to you — passphrases and FIDO2 tokens in any combination,
managed with `systemd-cryptenroll`. **All recipes, traps, and the
token-only checklist: [docs/fde.md](fde.md).**

**To unlock with a token at boot**, enable boot-side support in
`configuration.nix` and rebuild *before* relying on it:

```nix
core.fde.fido2.enable = true;
# If you partitioned manually and the mapper isn't the installer's
# "cryptroot", name it — the build refuses to attach FIDO2 to a volume
# that doesn't exist:
#   core.fde.name = "nixos-enc";
# and if the generated hardware config doesn't declare the LUKS device
# at all, declare it directly:
#   boot.initrd.luks.devices.nixos-enc.device = "/dev/nvme0n1p2";
```

Then `sudo nixos-rebuild switch --flake ~/.nixos`, enroll a token (see
the guide), and reboot to test: token inserted → PIN + touch; absent →
passphrase prompt.

Going token-only is supported — follow the guide's checklist exactly; a
token-only volume with a lost sole token is unrecoverable by design.

## 6. Optional: VPNs (tailscale / NymVPN)

**On the target machine, as the admin user.**

VPN membership is machine policy; only the admin sets anything up, and
neither VPN gates anyone's login:

- **NymVPN** is the machine's default route. `nym-vpn-autoconnect` brings
  the tunnel up at every boot, for everyone, before anybody logs in.
- **tailscale** carries *only* tailnet destinations (`100.64.0.0/10` and
  MagicDNS names) — never give it an exit node — and is up only when the
  admin has run `sudo tailscale up`.

**NymVPN** (`core.nymvpn.enable`): store the machine's account once, as a
wheel user, then kick the autoconnect service (afterwards it's automatic
at boot):

```sh
nym-vpnc account store        # prompts for the mnemonic; stored daemon-side, machine-wide
sudo systemctl restart nym-vpn-autoconnect
nym-vpnc status
```

`sudo systemctl stop nym-vpn-autoconnect` disconnects until the next boot.

**tailscale** (`core.tailscale.enable`): the daemon runs, but nothing
connects on its own. Enroll and connect by hand:

```sh
sudo tailscale up --login-server=https://your.headscale.example
sudo tailscale down                                # when done
```

The first `up` prints an auth URL (or pass `--auth-key=tskey-…` from
`headscale preauthkeys create`); tailscaled remembers the enrollment in
`/var/lib/tailscale`, so later `up`s connect immediately.

## 7. Each user sets up their home

**On the target machine, as each user (not root).**

Every user (including the admin) applies their own environment from
their own dotfiles repo. A user without one can skip this entirely: with
`core.desktop.enable` they get the full niri + Noctalia desktop from the
system default (`/etc/niri/config.kdl`), and Noctalia settings-UI
changes persist in their own `~/.local/state/noctalia/settings.toml`.

Dotfiles personalize the desktop by shipping `~/.config/niri/config.kdl`
(it replaces the system file wholesale — start from a copy of
`modules/niri-default-config.kdl`), and can capture Noctalia settings by
symlinking `~/.local/state/noctalia/settings.toml` into the repo
checkout with mkOutOfStoreSymlink —
[nullcopy/dotfiles](https://github.com/nullcopy/dotfiles) does both.

**If the user already has a dotfiles repo**
([nullcopy/dotfiles](https://github.com/nullcopy/dotfiles) is the reference
layout):

```sh
git clone git@github.com:<user>/dotfiles ~/.dotfiles
nix run home-manager -- switch --flake ~/.dotfiles
```

Two prerequisites, both in the dotfiles repo, not the machine repo: it must
define a `homeConfigurations."<user>@<hostname>"` entry for this machine,
and if it's cloned somewhere other than `~/.dotfiles` the entry must pass
the repo path so any mutable-config symlinks resolve.

**Starting from zero**, a complete minimal dotfiles repo is two files.
`flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... }: {
    homeConfigurations."bob@fern" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ ./home.nix ];
    };
  };
}
```

`home.nix`:

```nix
{ pkgs, ... }:
{
  home.username = "bob";
  home.homeDirectory = "/home/bob";
  home.stateVersion = "25.11";   # HM version at first setup; never bump

  programs.home-manager.enable = true;   # keeps the CLI installed
  home.packages = with pkgs; [ ripgrep ];
  programs.git = {
    enable = true;
    settings.user = { name = "bob"; email = "bob@example.com"; };
  };
}
```

Then `nix run home-manager -- switch --flake ~/.dotfiles` and grow it from
there. After the first run, plain `home-manager switch --flake ~/.dotfiles`
applies future changes — home-manager picks the `<user>@<hostname>` entry
automatically.

## 8. Day to day

```sh
sudo nixos-rebuild switch --flake ~/.nixos    # apply machine changes
nix flake update core                        # (in ~/.nixos) pull nixos-core improvements
nix flake update                             # bump everything (core + nixpkgs)
home-manager switch --flake ~/.dotfiles      # apply home changes (per user)
```

System and home update on independent schedules — that's by design. A
`nixos-rebuild` never touches user homes, and `home-manager switch` never
needs root.

## Common gotchas

- **`error: flake ... does not provide attribute`** on rebuild: the
  `nixosConfigurations.<name>` attribute doesn't match this machine's
  hostname. Make them identical.
- **A `core.*` change doesn't arrive on a machine**: machine repos pin core
  in `flake.lock`. Run `nix flake update core` there — updates are pulled
  deliberately, never automatic.
- **`git` complains about dubious ownership**: plain git work never needs
  sudo — drop it. For root's git during a rebuild, see the
  `safe.directory` note in step 4.
