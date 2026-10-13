{
  config,
  lib,
  pkgs,
  ...
}:

# NymVPN daemon (nym-vpnd) and CLI client (nym-vpnc), packaged from the
# official release binaries (nixpkgs carries only the mixnet tools).
# One account per machine, stored in the daemon; the tunnel carries all
# users' traffic. The daemon keeps a requested connection alive but
# never initiates one: a wheel user runs `nym-vpnc connect`. Until that
# first connect, the gate unit below blocks network egress. Setup and
# daily commands: docs/vpn.md.

let
  # To update: bump version, then hash (from the release, or from the
  # first failed rebuild).
  version = "2026.10.0";

  nym-vpn-core = pkgs.stdenv.mkDerivation {
    pname = "nym-vpn-core";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/nymtech/nym-vpn-client/releases/download/nym-vpn-core-v${version}/nym-vpn-core-v${version}_linux_x86_64.tar.gz";
      hash = "sha256-k5q4MtwiS2J8Q7bCpWIHO6XbzVMFeavjvhOtH9ITbJs=";
    };

    sourceRoot = "nym-vpn-core-v${version}_linux_x86_64";

    # autoPatchelfHook points the generic-Linux binaries at nix store
    # libraries. The buildInputs list comes from readelf -d.
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = with pkgs; [
      dbus
      libmnl
      libnftnl
      stdenv.cc.cc.lib
    ];

    installPhase = ''
      runHook preInstall
      install -Dm755 nym-vpnd nym-vpnc -t $out/bin
      runHook postInstall
    '';

    meta = {
      description = "NymVPN daemon and CLI client (official prebuilt binaries)";
      homepage = "https://nym.com";
      license = lib.licenses.gpl3Only;
      platforms = [ "x86_64-linux" ];
    };
  };

  # nym-vpnd authorizes socket clients via a polkit action baked into
  # the binary. This ships the upstream .policy file that declares it
  # (systemPackages links share/polkit-1/actions into polkit's path).
  nym-vpnd-polkit-policy = pkgs.writeTextFile {
    name = "nym-vpnd-polkit-policy";
    destination = "/share/polkit-1/actions/com.nymvpn.vpnd.unix-access.policy";
    text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <policyconfig>
        <action id="com.nymvpn.vpnd.unix-access">
          <description>Connect via unix socket</description>
          <message>Authentication is required to connect to the daemon</message>

          <defaults>
            <allow_any>auth_admin</allow_any>
            <allow_inactive>auth_admin</allow_inactive>
            <allow_active>auth_self</allow_active>
          </defaults>
        </action>
      </policyconfig>
    '';
  };

  cfg = config.core.nymvpn;
in
{
  options.core.nymvpn.enable = lib.mkEnableOption "NymVPN daemon (nym-vpnd) and CLI client";

  config = lib.mkIf cfg.enable {
    ## ----- packages ------------------------------------------------------------
    environment.systemPackages = [
      nym-vpn-core
      nym-vpnd-polkit-policy
    ];

    ## ----- polkit --------------------------------------------------------------
    # Wheel users get daemon access without a prompt; the auth_self
    # default requires a polkit agent.
    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "com.nymvpn.vpnd.unix-access" &&
              (subject.user == "root" || subject.isInGroup("wheel"))) {
            return polkit.Result.YES;
          }
        });
      '';
    };

    ## ----- daemon --------------------------------------------------------------
    # The unit matches the official .deb, plus an explicit PATH: the
    # daemon runs these network tools at tunnel setup and fails with
    # Error(TunDevice) without them.
    systemd.services.nym-vpnd = {
      description = "NymVPN daemon";
      wantedBy = [ "multi-user.target" ];
      before = [ "network-online.target" ];
      after = [
        "NetworkManager.service"
        "systemd-resolved.service"
      ];
      path = with pkgs; [
        iproute2
        iptables
        nftables
        coreutils
      ];
      startLimitBurst = 6;
      startLimitIntervalSec = 24;
      serviceConfig = {
        ExecStart = "${nym-vpn-core}/bin/nym-vpnd -v run-as-service";
        Restart = "always";
        RestartSec = 2;
        # The gate's set of the daemon's cgroup ID (see the gate below).
        NFTSet = "cgroup:inet:nym-vpn-gate:daemon";
        # The daemon's own resolver reads /etc/resolv.conf. With the
        # upstream servers in its view of that file, its lookups leave
        # from its own cgroup, which the gate allows; the rest of the
        # system keeps resolved's stub. Optional (the leading dash): a
        # machine without resolved has the upstream servers in
        # /etc/resolv.conf already.
        BindReadOnlyPaths = [ "-/run/systemd/resolve/resolv.conf:/etc/resolv.conf" ];
      };
    };

    ## ----- boot gate -----------------------------------------------------------
    # nym-vpnd installs its firewall only once a connect is requested.
    # This unit covers the time before that: an nftables table from
    # early boot drops all egress except what the daemon needs to
    # connect. The daemon identifies its own traffic by destination and
    # root uid rather than a socket mark, and names its tun devices at
    # creation, so the table matches the daemon's cgroup and the tun
    # device kind instead. A service's cgroup ID changes on every
    # restart: NFTSet on nym-vpnd publishes the current one into the
    # table's set, and the script seeds the set for a daemon that is
    # already running, since systemd publishes only when a cgroup is
    # created. The cgroup match exists only in the output hook, so a
    # forward chain covers forwarded traffic separately. The unit then
    # waits for `nym-vpnc status` to report the tunnel connected,
    # removes the table and stays active (exited), so a rebuild switch
    # does not run it again; a later disconnect leaves traffic unguarded
    # until the next boot. Ordering follows the NixOS firewall unit, so
    # the table is up before any interface. Stop the unit to lift the
    # gate by hand; a marker in /run then keeps it down until the next
    # boot, since a rebuild switch starts every active target and would
    # otherwise pull the unit back in through sysinit.target.
    #
    # DNS is dropped for everything but the daemon, which resolves
    # through its own view of resolv.conf (see the daemon unit). A
    # script error after the table is in also removes it (ExecStopPost),
    # so the gate fails open.
    #
    # Tailscale marks its underlay traffic with 0x80000 in bits 16-23;
    # that constant is tailscale-internal.
    systemd.services.nym-vpn-gate = {
      description = "Block network egress until the NymVPN tunnel is up";
      wantedBy = [ "sysinit.target" ];
      wants = [ "network-pre.target" ];
      before = [ "network-pre.target" ];
      after = [ "systemd-modules-load.service" ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "!/run/nym-vpn-gate.lifted";
      };
      # A changed unit applies at the next boot rather than re-engaging
      # the gate on a switch.
      restartIfChanged = false;
      path = [
        pkgs.nftables
        nym-vpn-core
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
          "-${pkgs.nftables}/bin/nft delete table inet nym-vpn-gate"
          "${pkgs.coreutils}/bin/touch /run/nym-vpn-gate.lifted"
        ];
      };
      script = ''
        nft -f - <<'EOF'
        table inet nym-vpn-gate { }
        delete table inet nym-vpn-gate
        table inet nym-vpn-gate {
          # Filled by NFTSet on nym-vpnd and seeded below.
          set daemon { type cgroupsv2; }
          chain egress {
            type filter hook output priority filter; policy drop;
            oifname "lo" accept
            # The daemon's gateway, API and resolver traffic.
            socket cgroupv2 level 2 @daemon accept
            # The daemon's tun devices and tailscale's.
            meta oifkind "tun" accept
            # Tailscale's marked underlay traffic.
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
          # Forwarded traffic (containers, VMs) never passes the output hook.
          chain forward {
            type filter hook forward priority filter; policy drop;
            meta oifkind "tun" accept
            ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 } accept
            ip6 daddr { fe80::/10, fc00::/7, ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 } accept
          }
        }
        EOF
        # A daemon already running has a cgroup ID that NFTSet published
        # before this table existed.
        id=$(systemctl show -p ControlGroupId --value nym-vpnd.service)
        if [ "$id" != 0 ]; then
          nft add element inet nym-vpn-gate daemon "{ $id }"
        fi
        systemd-notify --ready
        # The daemon comes up later in the boot; until then status fails.
        until nym-vpnc status 2>/dev/null | grep -q '^State: Connected'; do
          sleep 5
        done
        nft delete table inet nym-vpn-gate
      '';
    };
  };
}
