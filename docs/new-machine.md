# Set up a new machine from scratch

From bare hardware to a configured NixOS machine with per-user homes.
Generic NixOS steps (ISO download, USB stick) link to the official
manual.

## Repository structure

```
github:nullcopy/nixos-core          <- shared library (this repo)
        ^ flake input
github:nullcopy/nixos-<hostname>    <- the machine's own repo (one per machine)
                                       hostname, hardware, core.* toggles, accounts

github:<user>/dotfiles              <- each user's home environment,
                                       applied with standalone home-manager
```

- A machine repo is ~50 lines of config plus the generated hardware
  config; [nixos-wisp](https://github.com/nullcopy/nixos-wisp) is a real
  example.
- Users apply their homes with standalone
  [home-manager](https://github.com/nix-community/home-manager) (step 7);
  [nullcopy/dotfiles](https://github.com/nullcopy/dotfiles) is the
  reference layout.

## What you need

- The **target machine** and an erasable USB stick (>= 2 GB).
- A **working computer** (any OS) to prepare the repo and the USB stick.
- A GitHub (or other git host) account for the machine repo.

Each step names the machine it runs on.

## 1. Create the machine repo

**On the working computer.**

Select a lowercase hostname, for example `fern`. With nix:

```sh
mkdir nixos-fern && cd nixos-fern
nix flake init -t github:nullcopy/nixos-core#machine
git init
```

Without nix, copy the template manually (the trailing `/.` also copies
the hidden `.githooks/` directory):

```sh
git clone https://github.com/nullcopy/nixos-core
mkdir nixos-fern
cp -r nixos-core/templates/machine/. nixos-fern/ && cd nixos-fern && git init
```

Edit `flake.nix` and `configuration.nix`.

### flake.nix

Replace `MYHOSTNAME`:

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

### configuration.nix

Replace `MYHOSTNAME` and `MYADMIN`, and set the toggles. A complete
headless-server example:

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

For a desktop or laptop, set `core.desktop.enable = true`.
[nixos-wisp's configuration.nix](https://github.com/nullcopy/nixos-wisp/blob/main/configuration.nix)
shows hardware-specific settings and the FIDO2 options in real use.

The `core.*` options (source in [modules/](../modules)):

| Option | What it enables |
|---|---|
| `core.desktop.enable` | Complete desktop for every user: niri + Noctalia (default config `/etc/niri/config.kdl`), greetd session menu, pipewire, bluetooth |
| `core.fde.*` | Mandatory FDE (build assertion); `fido2.enable` adds YubiKey boot unlock (step 5, [docs/fde.md](fde.md)) |
| `core.tailscale.enable` | tailscale daemon; the admin runs `sudo tailscale up` / `down`, tailnet traffic only (step 6) |
| `core.nymvpn.enable` | NymVPN daemon + CLI; the machine-wide tunnel connects at boot (step 6) |

`base.nix` values carry `lib.mkDefault`, so overrides here take effect
without conflicts.

### Push the machine repo

```sh
git add -A && git commit -m "Initial config for fern"
git remote add origin git@github.com:<you>/nixos-fern.git
git push -u origin main
```

A public repo installs simplest (the install script clones over https).
Keep secrets out of the repo in either case.

## 2. Boot the NixOS installer

**On the working computer, then on the target machine.**

Follow the official manual's
["Installation" chapter](https://nixos.org/manual/nixos/stable/#sec-installation):
download an ISO, write it to the USB stick, boot the target machine from
it, and confirm the network with `ping github.com`. **Stop before the
manual's "Partitioning and formatting" section**; the install script
does the disk setup.

## 3. Run the install script

**On the target machine, in the live environment.**

> **Warning:** the install script wipes one whole disk. It creates a GPT
> layout with a 1 GB EFI partition and a LUKS2-encrypted btrfs root
> (subvolumes `@`, `@home`, `@nix`, `@log`, `@snapshots`). For a
> different layout, partition manually with the
> [official manual](https://nixos.org/manual/nixos/stable/#sec-installation),
> then: clone the machine repo, generate `hardware-configuration.nix`
> into it, and run `nixos-install --flake`.

```sh
curl -O https://raw.githubusercontent.com/nullcopy/nixos-core/main/scripts/nixos-install.sh
vim nixos-install.sh    # set the four variables at the top:
                        #   DISK         e.g. /dev/nvme0n1 — check with lsblk!
                        #   MACHINE_REPO your repo's https URL
                        #   HOSTNAME     e.g. fern
                        #   ADMINUSER    the wheel user, e.g. alice
sudo bash nixos-install.sh
```

The install script:

1. Confirms with `YES`, erases and partitions the disk, and asks for the
   **disk passphrase** (this unlocks the machine at every boot).
2. Clones `MACHINE_REPO` to `/mnt/home/<ADMINUSER>/.nixos`, generates
   `hardware-configuration.nix`, creates `flake.lock`, commits both, and
   activates the pre-commit hook.
3. Prints `ok`/`WARNING` checks (hostname, flake attribute, admin user),
   offers a review shell for corrections, then asks for a second `YES`.
4. Runs `nixos-install` (the first install takes a while), asks for
   `ADMINUSER`'s login password, and hands the repo to `ADMINUSER`.

Remove the USB stick and reboot. Enter the disk passphrase; a login
prompt (or the greeter, with the desktop enabled) appears. In the
greeter, **F3** selects the niri session or a plain **Shell** session.

If the install script fails, run it again from the start; it cleans up
the previous attempt first. If it failed *after* the clone step, you can
finish manually — the disk is still mounted at `/mnt`:

```sh
nixos-install --flake "path:/mnt/home/<ADMINUSER>/.nixos#<HOSTNAME>" --no-root-password
nixos-enter --root /mnt -- passwd <ADMINUSER>
nixos-enter --root /mnt -- chown -R <ADMINUSER>:users /home/<ADMINUSER>
umount -R /mnt && cryptsetup close cryptroot
```

## 4. First boot

**On the target machine, as the admin user.**

The machine repo is at `~/.nixos`, owned by you; only the rebuild needs
sudo.

```sh
cd ~/.nixos
git push                              # the installer's hardware-config + flake.lock commit
sudo nixos-rebuild switch --flake ~/.nixos   # should be a no-op right now
```

- Edits from the review shell: `git add -A && git commit` first.
- The pre-commit hook is active in this clone; on any other clone, run
  `git config core.hooksPath .githooks` once.
- The committed `flake.lock` makes nixos-core updates deliberate
  (`nix flake update core`).
- Other users: set their initial passwords with `sudo passwd bob`.
- The root account is locked; use `sudo` (or `sudo -i` for a root
  shell).

## 5. Disk unlock methods (passphrases & YubiKeys)

**On the target machine, as the admin user.**

The install script created a LUKS volume with your passphrase. Add or
remove unlock methods with `systemd-cryptenroll` —
**[docs/fde.md](fde.md) is the command catalog, including the token-only
checklist.**

**To unlock with a token at boot**, enable boot-side support in
`configuration.nix` and rebuild *before* you rely on the token:

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

Then `sudo nixos-rebuild switch --flake ~/.nixos`, enroll a token, and
reboot to test: token inserted → PIN + touch; token absent → passphrase
prompt.

## 6. Optional: VPNs (tailscale / NymVPN)

**On the target machine, as the admin user.**

VPN membership is machine policy; only the admin configures it, and a
login works without any VPN credentials.

- **NymVPN** is the machine's default route; the tunnel starts at every
  boot, before any login.
- **tailscale** carries tailnet destinations (`100.64.0.0/10`, MagicDNS)
  only, and only after the admin runs `sudo tailscale up`.

**NymVPN** (`core.nymvpn.enable`): store the machine account once, then
restart the service; every later boot connects automatically:

```sh
read -rs MNEMONIC                  # paste the account mnemonic (stays out of shell history)
nym-vpnc account set "$MNEMONIC"   # stored daemon-side, machine-wide
sudo systemctl restart nym-vpn-autoconnect
nym-vpnc status
```

`sudo systemctl stop nym-vpn-autoconnect` disconnects until the next
boot.

**tailscale** (`core.tailscale.enable`): enroll and connect manually:

```sh
sudo tailscale up --login-server=https://your.headscale.example
sudo tailscale down                                # when done
```

The first `up` prints an auth URL (or pass `--auth-key=tskey-…` from
`headscale preauthkeys create`); tailscaled stores the enrollment, so
later `up` commands connect immediately.

## 7. Each user sets up their home

**On the target machine, as each user (not root).**

Every user (the admin included) applies their environment from their own
dotfiles repo. A user without one can skip this step: with
`core.desktop.enable` they get the full niri + Noctalia desktop, and
their Noctalia settings persist in
`~/.local/state/noctalia/settings.toml`.

A dotfiles repo personalizes the desktop with its own
`~/.config/niri/config.kdl` (start from a copy of
`modules/niri-default-config.kdl`; it replaces the whole system file)
and can capture the Noctalia settings by symlinking
`~/.local/state/noctalia/settings.toml` into the checkout with
mkOutOfStoreSymlink.
[nullcopy/dotfiles](https://github.com/nullcopy/dotfiles) does both.

**With an existing dotfiles repo:**

```sh
git clone git@github.com:<user>/dotfiles ~/.dotfiles
nix run home-manager -- switch --flake ~/.dotfiles
```

The dotfiles repo must define a
`homeConfigurations."<user>@<hostname>"` entry for this machine, and
must pass the repo path if the checkout is somewhere other than
`~/.dotfiles`.

**From zero**, a minimal dotfiles repo is two files. `flake.nix`:

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

After the first `nix run home-manager -- switch --flake ~/.dotfiles`,
plain `home-manager switch --flake ~/.dotfiles` applies future changes;
home-manager selects the `<user>@<hostname>` entry automatically.

## 8. Routine tasks

```sh
sudo nixos-rebuild switch --flake ~/.nixos    # apply machine changes
nix flake update core                        # (in ~/.nixos) pull nixos-core improvements
nix flake update                             # bump everything (core + nixpkgs)
home-manager switch --flake ~/.dotfiles      # apply home changes (per user)
```

## Common problems

- **`error: flake ... does not provide attribute`** on rebuild: the
  `nixosConfigurations.<name>` attribute must equal the hostname.
- **A `core.*` change does not arrive on a machine**: machine repos pin
  core in `flake.lock`; run `nix flake update core` on that machine.
- **`git` reports dubious ownership**: plain git work needs no sudo. For
  root's git during a rebuild, run once:
  `sudo git config --global --add safe.directory ~/.nixos`.
