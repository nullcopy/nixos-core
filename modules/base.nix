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

  ## ----- memory --------------------------------------------------------------
  # Guardrails that keep a runaway build from freezing the host.

  # nix-daemon runs builds in its own cgroup, so a hard cap turns a
  # runaway build into a failed build. OOMPolicy stays "continue" (the
  # NixOS default) so the daemon survives its builder being killed.
  # Builds run from a user shell are not in this cgroup.
  systemd.services.nix-daemon.serviceConfig.MemoryMax = lib.mkDefault "75%";

  # Compressed swap in RAM. Nothing is written to disk: NixOS's zram
  # module has no writeback device unless one is set, so swapped pages
  # never leave memory. Its job is the pressure signal, not capacity:
  # with swap present, memory pressure builds gradually before the OOM
  # killer fires, which is what oomd needs to act first. memoryPercent
  # caps uncompressed content, so RAM actually spent is a third or so
  # of it. 25% is enough for the signal; more only prolongs thrashing
  # when pages compress badly.
  zramSwap.enable = lib.mkDefault true;
  zramSwap.memoryPercent = lib.mkDefault 25;

  ## ----- networking ----------------------------------------------------------
  networking.networkmanager.enable = lib.mkDefault true;
  networking.firewall.enable = lib.mkDefault true;

  # The VPN daemons rewrite DNS. Without resolved, nym-vpnd overwrites
  # /etc/resolv.conf and a later `tailscale up` fails with "signature
  # mismatch"; the obscura daemon configures resolved over D-Bus.
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

  ## ----- git -----------------------------------------------------------------
  # The machine repo at /etc/nixos is owned by the admin. The exception
  # lets root read it too, for `sudo nixos-rebuild switch`; Nix honors
  # it like git does.
  programs.git = {
    enable = lib.mkDefault true;
    config.safe.directory = "/etc/nixos";
  };

  ## ----- shells --------------------------------------------------------------
  # System-level zsh puts zsh in /etc/shells as a valid login shell.
  programs.zsh.enable = lib.mkDefault true;

  ## ----- packages ------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    vim
    curl
    wget
    bottom
    magic-wormhole
    nixfmt
    tree
    pv
  ];
}
