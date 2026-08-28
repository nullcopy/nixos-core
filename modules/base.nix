{
  config,
  lib,
  pkgs,
  ...
}:

# Always-on baseline for every machine. Opinionated values use
# lib.mkDefault so a machine config can override them without mkForce.
{
  ## ----- nix -----------------------------------------------------------------
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Garbage collection for nix generations
  nix.gc = {
    automatic = lib.mkDefault true;
    dates = lib.mkDefault "daily";
    options = lib.mkDefault "--delete-older-than 14d";
  };

  ## ----- networking ----------------------------------------------------------
  networking.networkmanager.enable = lib.mkDefault true;
  networking.firewall.enable = lib.mkDefault true;

  # DNS broker, required for tailscale and nymvpn to coexist. Both rewrite
  # DNS config on connect/disconnect; without resolved, nym-vpnd falls back
  # to overwriting /etc/resolv.conf directly, which invalidates openresolv's
  # file signature and breaks `tailscale up` afterwards ("signature mismatch:
  # /etc/resolv.conf"). With resolved enabled, both daemons (and
  # NetworkManager, which NixOS points at resolved automatically) set
  # per-link DNS over D-Bus instead of fighting over the file.
  services.resolved.enable = lib.mkDefault true;

  ## ----- gpg -----------------------------------------------------------------
  programs.gnupg.agent = {
    enable = lib.mkDefault true;
    pinentryPackage = lib.mkDefault pkgs.pinentry-curses;
  };
  services.pcscd.enable = lib.mkDefault true;

  ## ----- root ----------------------------------------------------------------
  # Direct root login is disabled: the account's password is locked ("!").
  # Administration happens through wheel users and sudo (`sudo -i` for a
  # root shell). The install script's --no-root-password already leaves root
  # locked; declaring it here makes that a property of the config rather
  # than of the install path. Note: with the default users.mutableUsers =
  # true this is applied when the system is first created — on an existing
  # machine, verify with `sudo passwd -S root` (expect "L").
  users.users.root.hashedPassword = lib.mkDefault "!";

  ## ----- shells --------------------------------------------------------------
  # System-level so zsh is in /etc/shells and usable as a login shell.
  programs.zsh.enable = lib.mkDefault true;

  ## ----- packages ------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    bottom
    magic-wormhole
    nixfmt
    tree
    pv
  ];
}
