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
# disconnect. Until that first connect, the gate unit below blocks
# network egress. Setup and daily commands: docs/vpn.md.

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

    ## ----- boot gate -----------------------------------------------------------
    # The daemon starts every boot with the tunnel inactive and installs
    # its kill switch only while connecting or connected. This unit
    # covers the time before that: an nftables table from early boot
    # drops all egress except what the daemon's own kill switch exempts,
    # so `obscura connect` works under it. The unit then waits for the
    # daemon to report the tunnel connected, removes the table and stays
    # active (exited), so a rebuild switch does not run it again; a later
    # disconnect leaves traffic unguarded until the next boot. Ordering
    # follows the NixOS firewall unit, so the table is up before any
    # interface. Stop the unit to lift the gate by hand; a marker in
    # /run then keeps it down until the next boot, since a rebuild
    # switch starts every active target and would otherwise pull the
    # unit back in through sysinit.target.
    #
    # DNS is dropped, the daemon's own lookups included: it resolves its
    # API through the system resolver but ships a cached address, so a
    # connect works until that address goes stale. The gate then holds
    # until the unit is stopped. A script error after the table is in
    # also removes it (ExecStopPost), so the gate fails open.
    #
    # The daemon sets the 0x6f627363 fwmark ("obsc") on its relay and
    # API sockets; tailscale marks its underlay with 0x80000 in bits
    # 16-23. Both are upstream internals: a change in a release leaves
    # the daemon unable to connect under the gate.
    systemd.services.obscura-gate = {
      description = "Block network egress until the Obscura tunnel is up";
      wantedBy = [ "sysinit.target" ];
      wants = [ "network-pre.target" ];
      before = [ "network-pre.target" ];
      after = [ "systemd-modules-load.service" ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "!/run/obscura-gate.lifted";
      };
      # A changed unit applies at the next boot rather than re-engaging
      # the gate on a switch.
      restartIfChanged = false;
      path = [
        pkgs.nftables
        obscura
      ];
      serviceConfig = {
        # Ready once the table is in place; the wait for the tunnel
        # happens after that.
        Type = "notify";
        NotifyAccess = "all";
        RemainAfterExit = true;
        # A stop after the script's own delete finds no table, hence the
        # ignored error. The marker keeps a stopped gate down for the
        # rest of the boot (see ConditionPathExists).
        ExecStopPost = [
          "-${pkgs.nftables}/bin/nft delete table inet obscura-gate"
          "${pkgs.coreutils}/bin/touch /run/obscura-gate.lifted"
        ];
      };
      script = ''
        nft -f - <<'EOF'
        table inet obscura-gate { }
        delete table inet obscura-gate
        table inet obscura-gate {
          chain egress {
            type filter hook postrouting priority filter; policy drop;
            oifname "lo" accept
            # The daemon's relay and API traffic.
            meta mark 0x6f627363 accept
            oifname "obscuravpn" accept
            # Tailscale's device and its marked underlay traffic.
            oifname "tailscale0" accept
            meta mark & 0x00ff0000 == 0x00080000 accept
            # Link scope DHCP and IPv6 neighbor discovery.
            ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept
            ip6 daddr ff02::1:2 udp sport 546 udp dport 547 accept
            icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
            # DNS to local resolvers.
            udp dport { 53, 853 } drop
            tcp dport { 53, 853 } drop
            # Local network.
            ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 } accept
            ip6 daddr { fe80::/10, fc00::/7, ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 } accept
          }
        }
        EOF
        systemd-notify --ready
        # `status --follow` streams state changes; it exits when the
        # daemon is not up yet, so retry until the connected line shows.
        # The follow never returns on its own and a pipeline would wait
        # for it, so it runs as a process substitution ($! is its PID)
        # and is killed after the match.
        until exec 3< <(obscura status --follow 2>/dev/null) && grep -q -m1 '^VPN is connected' <&3; do
          sleep 5
        done
        kill "$!" 2>/dev/null || true
        exec 3<&-
        nft delete table inet obscura-gate
      '';
    };
  };
}
