{
  config,
  lib,
  pkgs,
  ...
}:

# Boot egress gates. A gate installs an nftables table from early boot
# that drops all egress except the traffic its tunnel needs, so a
# machine has no network access before (and, for a gate that keeps its
# table, outside) the tunnel. The VPN modules declare their gates
# through the internal `core.internal.egressGates` option; this module
# supplies the unit, the loopback and link-local allows, the DNS drop,
# the local-network allows and the cgroup-set publishing that names a
# daemon's own traffic.
let
  gates = config.core.internal.egressGates;

  indent = line: "    ${line}";

  # The DHCP/ND, DNS and local-network block, identical for every gate.
  # The DNS drop is before the local-network accept, so a lookup to a
  # LAN resolver is dropped too: name resolution has to leave through
  # the tunnel (which the gate's own rules accept) or not at all.
  egressTail = [
    "# Link scope DHCP and IPv6 neighbor discovery."
    "ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept"
    "ip6 daddr ff02::1:2 udp sport 546 udp dport 547 accept"
    "icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept"
    "# DNS to local resolvers."
    "udp dport { 53, 853 } drop"
    "tcp dport { 53, 853 } drop"
    "# Local network."
    "ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 } accept"
    "ip6 daddr { fe80::/10, fc00::/7, ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 } accept"
  ];

  forwardTail = [
    "ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 } accept"
    "ip6 daddr { fe80::/10, fc00::/7, ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 } accept"
  ];

  mkScript =
    name: gate:
    lib.concatStringsSep "\n" (
      [
        "nft -f - <<'EOF'"
        "table inet ${gate.table} { }"
        "delete table inet ${gate.table}"
        "table inet ${gate.table} {"
      ]
      ++ lib.optionals (gate.cgroupUnit != null) [
        "  # Filled by NFTSet on ${lib.removeSuffix ".service" gate.cgroupUnit} and seeded below."
        "  set daemon { type cgroupsv2; }"
      ]
      ++ [
        "  chain egress {"
        "    type filter hook ${gate.hook} priority filter; policy drop;"
        "    oifname \"lo\" accept"
      ]
      ++ map indent gate.egressRules
      ++ map indent egressTail
      ++ [ "  }" ]
      ++ lib.optionals gate.forward (
        [
          "  # Forwarded traffic (containers, VMs) never passes the output hook."
          "  chain forward {"
          "    type filter hook forward priority filter; policy drop;"
          "    meta oifkind \"tun\" accept"
        ]
        ++ map indent gate.forwardRules
        ++ map indent forwardTail
        ++ [ "  }" ]
      )
      ++ [
        "}"
        "EOF"
      ]
      ++ lib.optionals (gate.cgroupUnit != null) [
        "# A daemon already running has a cgroup ID that NFTSet published"
        "# before this table existed."
        "id=$(systemctl show -p ControlGroupId --value ${gate.cgroupUnit})"
        "if [ \"$id\" != 0 ]; then"
        "  nft add element inet ${gate.table} daemon \"{ $id }\""
        "fi"
      ]
      ++ [ "systemd-notify --ready" ]
      ++ lib.optional (gate.wait != "") (lib.removeSuffix "\n" gate.wait)
      ++ lib.optionals (!gate.keepTable) [ "nft delete table inet ${gate.table}" ]
    )
    + "\n";
in
{
  options.core.internal.egressGates = lib.mkOption {
    internal = true;
    default = { };
    description = "Boot egress gates declared by the VPN modules.";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            description = lib.mkOption {
              type = lib.types.str;
              default = "Block network egress until the tunnel is up";
              description = "The unit's Description.";
            };

            table = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "nftables table name (an `inet` table).";
            };

            marker = lib.mkOption {
              type = lib.types.str;
              default = "/run/${name}.lifted";
              description = ''
                A touched marker path that keeps the gate down for the
                rest of the boot after it is stopped by hand.
              '';
            };

            hook = lib.mkOption {
              type = lib.types.enum [
                "output"
                "postrouting"
              ];
              default = "output";
              description = "Hook for the egress chain.";
            };

            forward = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to add the forwarded-traffic chain.";
            };

            egressRules = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Rule lines for the egress chain, after the loopback
                accept and before the shared DHCP/ND, DNS and
                local-network block.
              '';
            };

            forwardRules = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Rule lines for the forward chain, after the tun accept
                and before the shared local-network block.
              '';
            };

            cgroupUnit = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "nym-vpnd.service";
              description = ''
                A daemon unit whose cgroup ID identifies its own
                traffic. When set, the gate holds a cgroupv2 set named
                `daemon`, accepts that set in the egress chain, and
                publishes the unit's ID into the set.
              '';
            };

            packages = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              description = "Extra packages on the gate unit's PATH.";
            };

            wait = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = ''
                Commands run after the table is installed and the unit
                is ready, usually a loop that waits for the tunnel.
              '';
            };

            keepTable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Whether to keep the table after `wait` instead of
                deleting it. A gate that keeps its table goes on
                blocking egress outside the tunnel after it comes up.
              '';
            };
          };
        }
      )
    );
  };

  config.systemd.services = lib.mkMerge (
    [
      (lib.mapAttrs' (
        name: gate:
        lib.nameValuePair name {
          inherit (gate) description;
          wantedBy = [ "sysinit.target" ];
          wants = [ "network-pre.target" ];
          before = [ "network-pre.target" ];
          after = [ "systemd-modules-load.service" ];
          unitConfig = {
            DefaultDependencies = false;
            ConditionPathExists = "!${gate.marker}";
          };
          # A changed unit applies at the next boot rather than
          # re-engaging the gate on a switch.
          restartIfChanged = false;
          path = [ pkgs.nftables ] ++ gate.packages;
          serviceConfig = {
            # Ready once the table is in place; `wait` follows.
            Type = "notify";
            NotifyAccess = "all";
            RemainAfterExit = true;
            # A stop after the script's own delete finds no table,
            # hence the ignored error. The marker keeps a stopped gate
            # down for the rest of the boot (see ConditionPathExists).
            ExecStopPost = [
              "-${pkgs.nftables}/bin/nft delete table inet ${gate.table}"
              "${pkgs.coreutils}/bin/touch ${gate.marker}"
            ];
          };
          script = mkScript name gate;
        }
      ) gates)
    ]
    ++ lib.map (
      gate:
      # systemd.services keys its units by name without the ".service"
      # suffix; the gate stores the full name (for `systemctl show`).
      lib.setAttrByPath [
        (lib.removeSuffix ".service" gate.cgroupUnit)
        "serviceConfig"
        "NFTSet"
      ] "cgroup:inet:${gate.table}:daemon"
    ) (lib.filter (gate: gate.cgroupUnit != null) (lib.attrValues gates))
  );

  # A gate that fails to install or keep its table fails open: the unit
  # removes the table on any stop, an error included, so a gate that
  # never came up protects nothing. Surface it through core.alerts; the
  # failure is otherwise only in the journal. Names are without the
  # .service suffix.
  config.core.alerts.onFailure = lib.attrNames gates;
}
