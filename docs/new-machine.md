# Set up a new machine from scratch

From bare hardware to a configured NixOS machine with per-user homes.
Generic NixOS steps (ISO download, USB stick) link to the official
manual.

## What you need

- The **target machine** and an erasable USB stick (>= 2 GB).
- A **working computer** (any OS) to write the USB stick.
- Network on the target machine during the install; the script fetches
  nixos-core and nixpkgs.

Each step names the machine it runs on.

## 1. Boot the NixOS installer

**On the working computer, then on the target machine.**

Follow the official manual's
["Installation" chapter](https://nixos.org/manual/nixos/stable/#sec-installation):
download an ISO, write it to the USB stick, boot the target machine from
it, and confirm the network with `ping github.com`. **Stop before the
manual's "Partitioning and formatting" section**; the install script
does the disk setup.

## 2. Run the install script

**On the target machine, in the live environment.**

> **Warning:** the install script wipes one whole disk. It creates a GPT
> layout with a 1 GB EFI partition and a LUKS2-encrypted btrfs root
> (subvolumes `@`, `@home`, `@nix`, `@log`, `@snapshots`). For a
> different layout, partition manually with the
> [official manual](https://nixos.org/manual/nixos/stable/#sec-installation),
> then: scaffold the machine repo with
> `nix flake init -t github:nullcopy/nixos-core#machine`, replace the
> `MYHOSTNAME` and `MYADMIN` placeholders, generate
> `hardware-configuration.nix` into it, and run `nixos-install --flake`.

```sh
curl -O https://raw.githubusercontent.com/nullcopy/nixos-core/main/scripts/nixos-install.sh
sudo bash nixos-install.sh
```

The install script:

1. Asks for the disk (listed first; Tab completes under `/dev`), the
   hostname, the admin user, an existing repo to clone (empty for a
   fresh scaffold), and whether to enable ssh. Confirms with `YES`,
   erases and partitions the disk, and asks for the **disk passphrase**
   (this unlocks the machine at every boot).
2. Creates the machine repo at `/mnt/etc/nixos` from the
   nixos-core template with `HOSTNAME` and `ADMINUSER` filled in,
   generates `hardware-configuration.nix`, creates `flake.lock`, and
   commits it all with the pre-commit hook active.
3. Prints `ok`/`WARNING` checks (hostname, flake attribute, admin user)
   and opens a shell in the repo to edit `configuration.nix` (next
   section). Edits are committed on exit. Then it asks for a second
   `YES`.
4. Runs `nixos-install` (the first install takes a while), asks for
   `ADMINUSER`'s login password, and hands the repo to `ADMINUSER`.

### configuration.nix

The scaffold declares the hostname and the admin account, enables ssh
when asked for, and has every `core.*` toggle off. Set the toggles in the review shell (`vim
configuration.nix`), or later from the installed system followed by a
rebuild. `flake.nix` needs no edits: it defines
`nixosConfigurations.<hostname>` and pins nixos-core.

A complete headless-server example:

```nix
{ config, lib, pkgs, ... }:

{
  networking.hostName = "fern";     # must match the flake.nix attribute

  ## Localization
  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";

  ## What this machine gets from nixos-core (all default to off):
  core.desktop.enable = false;      # niri + greetd + audio + Wayland plumbing
  core.nymvpn.enable = true;        # NymVPN: machine-wide tunnel, manual `nym-vpnc connect` — see docs/vpn.md
  core.obscura.enable = false;      # Obscura VPN instead of NymVPN: one of the two — see docs/vpn.md
  core.tailscale.enable = true;     # tailscale daemon, manual `sudo tailscale up` — see docs/vpn.md
  # core.fde.fido2.enable = true;   # YubiKey disk unlock — see step 4

  ## Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  ## Accounts (homes come from each user's own repo — step 6)
  users.users.alice = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "networkmanager" ];   # wheel = sudo
  };
  users.users.bob = {
    isNormalUser = true;
    shell = pkgs.zsh;
  };

  ## ssh: key-only logins; keys live in each user's ~/.ssh/authorized_keys
  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    PermitRootLogin = "no";
  };

  ## Anything machine-specific goes here too:
  # environment.systemPackages = with pkgs; [ htop ];

  ## First NixOS version installed on this machine. Never bump on an
  ## existing install.
  system.stateVersion = "25.11";
}
```

For a desktop or laptop, set `core.desktop.enable = true`. Hardware
quirks go in the same file; a laptop might add firmware updates and a
newer kernel:

```nix
  services.fwupd.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
```

The `core.*` options (source in [modules/](../modules)):

| Option | What it enables |
|---|---|
| `core.desktop.enable` | Complete desktop for every user: niri + Noctalia (default config `/etc/niri/config.kdl`), greetd session menu, pipewire, bluetooth |
| `core.fde.*` | Mandatory FDE (build assertion); `fido2.enable` adds YubiKey boot unlock (step 4, [docs/fde.md](fde.md)) |
| `core.tailscale.enable` | tailscale daemon; the admin runs `sudo tailscale up` / `down`, tailnet traffic only ([docs/vpn.md](vpn.md)) |
| `core.nymvpn.enable` | NymVPN daemon + CLI; no network egress after boot until the admin runs `nym-vpnc connect`, then machine-wide default route ([docs/vpn.md](vpn.md)) |
| `core.obscura.enable` | Obscura VPN daemon + CLI; no network egress after boot until the admin runs `obscura connect`, then machine-wide default route; exclusive with `core.nymvpn.enable` ([docs/vpn.md](vpn.md)) |

`base.nix` values carry `lib.mkDefault`, so overrides here take effect
without conflicts.

### Reinstalling a machine

The machine repo lives only on the machine, so copy it off before
wiping the disk. A bundle holds the whole history in one file:

```sh
git -C /etc/nixos bundle create /run/media/<user>/<stick>/fern.bundle --all
```

In the live environment, answer the script's repo prompt with that file
(or any directory or URL `git clone` accepts). The script clones it in
place of the scaffold, regenerates `hardware-configuration.nix`, and
commits whatever changed.

### After the script

Remove the USB stick and reboot. Enter the disk passphrase; a login
prompt (or the greeter, with the desktop enabled) appears. In the
greeter, **F3** selects the niri session or a plain **Shell** session.

If the install script fails, run it again from the start; it cleans up
the previous attempt first. If it failed *after* the machine repo was
written, you can finish manually — the disk is still mounted at `/mnt`:

```sh
nixos-install --flake "path:/mnt/etc/nixos#<HOSTNAME>" --no-root-password
nixos-enter --root /mnt -- passwd <ADMINUSER>
nixos-enter --root /mnt -- chown -R <ADMINUSER>:users /etc/nixos
umount -R /mnt && cryptsetup close cryptroot
```

## 3. First boot

**On the target machine, as the admin user.**

The machine repo is at `/etc/nixos`, owned by you. Git runs as you.
`nixos-rebuild switch --sudo` evaluates and builds as you and uses sudo
for the activation only.

```sh
cd /etc/nixos
git log --oneline                # the installer's commits
nixos-rebuild switch --sudo      # should be a no-op right now
```

- The pre-commit hook is active in this repo; in a clone made some other
  way, run `git config core.hooksPath .githooks` once.
- The committed `flake.lock` makes nixos-core updates deliberate
  (`nix flake update core`).
- Other users: set their initial passwords with `sudo passwd bob`.
- The root account is locked; use `sudo` (or `sudo -i` for a root
  shell).

## 4. Disk unlock methods (passphrases & YubiKeys)

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

Then `nixos-rebuild switch --sudo`, enroll a token, and
reboot to test: token inserted → PIN + touch; token absent → passphrase
prompt.

## 5. Optional: VPNs (tailscale / NymVPN / Obscura)

**On the target machine, as the admin user.**

VPN membership is machine policy; only the admin configures it, and a
login works without any VPN credentials. The account setup and the
daily commands for each VPN are in [docs/vpn.md](vpn.md).

## 6. Each user sets up their home

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

## 7. Routine tasks

```sh
nixos-rebuild switch --sudo                  # apply machine changes
nix flake update core                        # (in /etc/nixos) pull nixos-core improvements
nix flake update                             # bump everything (core + nixpkgs)
home-manager switch --flake ~/.dotfiles      # apply home changes (per user)
```

## Common problems

- **`error: flake ... does not provide attribute`** on rebuild: the
  `nixosConfigurations.<name>` attribute must equal the hostname.
- **A `core.*` change does not arrive on a machine**: machine repos pin
  core in `flake.lock`; run `nix flake update core` on that machine.
