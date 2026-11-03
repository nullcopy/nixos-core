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
  # core.desktop.enable = true; # niri + greetd + audio + Wayland plumbing
  # core.nymvpn.enable = true; # NymVPN: machine-wide tunnel; no egress until the admin runs `nym-vpnc connect`
  # core.obscura.enable = true; # Obscura VPN: machine-wide tunnel; no egress until the admin runs `obscura connect`
  # core.tailscale.enable = true; # tailscale daemon; the admin runs `sudo tailscale up` manually
  # core.zfs.enable = true; # ZFS for data pools on attached drives; `mkzpool` creates one (docs/zfs.md)
  # core.backup.receive.enable = true; # accept raw ZFS backups from senders paired with `core-backup invite` (docs/backup.md)
  # core.backup.send.datasets."tank/encrypted".to = [ "obelisk" ]; # push raw backups to peers (docs/backup.md)
  # core.alerts.command = "..."; # where failed units, stale backups and pool events go (docs/backup.md)
  # core.caddy.enable = true; # TLS termination for forwarded :80/:443; set virtualHosts and openFirewallInterfaces
  # core.wireguard.enable = true; # a static tunnel to a relay; set address, privateKeyFile and peers
  # core.headscale.enable = true; # the tailnet control server; set serverUrl

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

  ## ----- ssh -----------------------------------------------------------------
  # Key-only logins; each user's keys live in ~/.ssh/authorized_keys.
  services.openssh.enable = false;
  services.openssh.settings = {
    PasswordAuthentication = false;
    PermitRootLogin = "no";
  };

  ## ----- machine-specific extras ----------------------------------------------
  # environment.systemPackages = with pkgs; [ ];

  ## ----- state version -------------------------------------------------------
  # The first NixOS version installed on this machine. Do not change it
  # on an existing installation. See `man configuration.nix`.
  system.stateVersion = "25.11";
}
