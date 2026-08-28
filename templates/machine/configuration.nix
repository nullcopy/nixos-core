{
  config,
  lib,
  pkgs,
  ...
}:

{
  ## ----- identity --------------------------------------------------------------
  networking.hostName = "MYHOSTNAME"; # must match the flake.nix attribute

  ## ----- localization --------------------------------------------------------
  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";

  ## ----- nixos-core toggles ------------------------------------------------
  # See modules/ in nixos-core for exactly what each one pulls in.
  core.desktop.enable = false; # niri + greetd + audio + Wayland plumbing
  core.nymvpn.enable = false; # NymVPN: machine-wide tunnel, auto-connects at boot
  core.tailscale.enable = false; # tailscale daemon; admin runs `sudo tailscale up` by hand

  # Optional: unlock the root LUKS volume with a YubiKey/FIDO2 token at
  # boot. Enable after install, then enroll a token with
  # systemd-cryptenroll — see docs/fde.md in nixos-core. (FDE itself is
  # mandatory; core.fde only configures HOW the volume unlocks.)
  # core.fde.fido2.enable = true;

  ## ----- boot ----------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  ## ----- users ---------------------------------------------------------------
  # Accounts are declared per machine. Each user manages their own home
  # environment from their own dotfiles repo with standalone home-manager;
  # the system only needs to know the account exists.
  users.users.MYADMIN = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };

  ## ----- machine-specific extras ----------------------------------------------
  # environment.systemPackages = with pkgs; [ ];

  ## ----- state version -------------------------------------------------------
  # The first NixOS version installed on this machine. Never bump it on an
  # existing install — see `man configuration.nix`.
  system.stateVersion = "25.11";
}
