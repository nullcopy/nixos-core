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
  # See modules/ in nixos-core for what each option enables.
  core.desktop.enable = false; # niri + greetd + audio + Wayland plumbing
  core.nymvpn.enable = false; # NymVPN: machine-wide tunnel, connects at boot
  core.tailscale.enable = false; # tailscale daemon; the admin runs `sudo tailscale up` manually

  # Optional: FIDO2 token unlock of the root volume at boot. Enroll
  # with systemd-cryptenroll after the install (docs/fde.md in
  # nixos-core).
  # core.fde.fido2.enable = true;

  ## ----- boot ----------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  ## ----- users ---------------------------------------------------------------
  # Each machine declares its accounts; users manage their homes from
  # their own dotfiles repos with standalone home-manager.
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
  # The first NixOS version installed on this machine. Do not change it
  # on an existing installation. See `man configuration.nix`.
  system.stateVersion = "25.11";
}
