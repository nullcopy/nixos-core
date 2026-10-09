{
  config,
  lib,
  pkgs,
  ...
}:

# Obscura VPN daemon and CLI (one binary, `obscura`), built from the
# upstream flake; nixpkgs has no package. One account per machine, kept
# by the daemon under /var/lib/obscura; the tunnel carries all users'
# traffic. Nothing connects at boot: a wheel user runs `obscura
# connect`, and the daemon's kill switch exists only from then until a
# disconnect. Setup and daily commands: docs/vpn.md.

let
  cfg = config.core.obscura;
  obscura = pkgs.obscura-cli;
in
{
  options.core.obscura.enable = lib.mkEnableOption "Obscura VPN daemon and CLI";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.core.nymvpn.enable;
        message = "core.obscura.enable and core.nymvpn.enable are both set; one VPN daemon owns the default route.";
      }
    ];

    ## ----- packages ------------------------------------------------------------
    environment.systemPackages = [ obscura ];

    ## ----- access --------------------------------------------------------------
    # The daemon's socket is open to group obscura. It checks the peer's
    # groups on every connection, so membership applies without a new
    # login. Wheel users are members.
    users.groups.obscura.members = lib.attrNames (
      lib.filterAttrs (_: user: lib.elem "wheel" user.extraGroups) config.users.users
    );

    ## ----- daemon --------------------------------------------------------------
    # The unit matches the upstream linux/common/obscura.service. Routes
    # and nftables go over netlink and DNS over D-Bus to resolved, so
    # the daemon needs no tools on PATH. It seals the WireGuard key to
    # the TPM when one is present.
    systemd.services.obscura = {
      description = "Obscura VPN daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "notify";
        ExecStart = "${obscura}/bin/obscura service";
        FileDescriptorStoreMax = 8;
        Group = "obscura";
        UMask = "0007";
        StateDirectory = "obscura";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "obscura";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = "restart";
        LogsDirectory = "obscura";
        LogsDirectoryMode = "0750";
        Restart = "always";
        RestartSec = 1;
        RestartSteps = 5;
        RestartMaxDelaySec = 30;
      };
    };
  };
}
