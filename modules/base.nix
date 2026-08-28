{
  config,
  lib,
  pkgs,
  ...
}:

# Baseline for every machine. Default values use lib.mkDefault so a
# machine configuration can override them without mkForce.
{
  ## ----- nix -----------------------------------------------------------------
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.gc = {
    automatic = lib.mkDefault true;
    dates = lib.mkDefault "daily";
    options = lib.mkDefault "--delete-older-than 14d";
  };

  ## ----- networking ----------------------------------------------------------
  networking.networkmanager.enable = lib.mkDefault true;
  networking.firewall.enable = lib.mkDefault true;

  # Both VPN daemons rewrite DNS. Without resolved, nym-vpnd overwrites
  # /etc/resolv.conf and a later `tailscale up` fails with "signature
  # mismatch".
  services.resolved.enable = lib.mkDefault true;

  ## ----- gpg -----------------------------------------------------------------
  programs.gnupg.agent = {
    enable = lib.mkDefault true;
    pinentryPackage = lib.mkDefault pkgs.pinentry-curses;
  };
  services.pcscd.enable = lib.mkDefault true;

  ## ----- root ----------------------------------------------------------------
  # Root's password is locked ("!"); admin work goes through sudo. With
  # mutableUsers = true this applies at first creation (`sudo passwd -S
  # root` shows "L").
  users.users.root.hashedPassword = lib.mkDefault "!";

  ## ----- shells --------------------------------------------------------------
  # System-level zsh puts zsh in /etc/shells as a valid login shell.
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
