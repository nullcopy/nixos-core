{
  config,
  lib,
  pkgs,
  ...
}:

# Client side of a full-tunnel WireGuard exit: every packet not
# addressed to the relay itself leaves through the tunnel, and the
# relay's address is the one carve-out, so the handshake and its replies
# can use the physical link. The relay side is plain
# networking.wireguard.interfaces, one host-route peer per client; the
# tunnel address of each client is allocated in the relay's repo.
# docs/vpn.md covers both ends, key generation and the boot gate.
let
  cfg = config.core.wireguardExit;

  # The gate's nftables rules embed the endpoint, nft rejects a malformed
  # address or port when it parses them, and a unit script runs under
  # `set -e`: one bad character would leave the table uninstalled, which
  # is no gate at all. Validate strictly here, and let the assertion
  # below reject the value with its message.
  isDecimal = s: builtins.match "[0-9]+" s != null;

  validPort = p: isDecimal p && lib.toInt p >= 1 && lib.toInt p <= 65535;

  validV4Octet = o: builtins.match "(0|[1-9][0-9]{0,2})" o != null && lib.toInt o <= 255;

  validV4 =
    a:
    let
      parts = lib.splitString "." a;
    in
    lib.length parts == 4 && lib.all validV4Octet parts;

  # Hex groups, at most one "::", at most eight groups, no embedded
  # IPv4. POSIX extended regexes have no non-capturing groups, so the
  # repeated shape is written out; the group count is checked separately,
  # because an elision may not stand for zero groups.
  validV6 =
    a:
    let
      groups = lib.filter (g: g != "") (lib.splitString ":" a);
      n = lib.length groups;
    in
    (builtins.match "([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}" a != null && n == 8)
    || (
      builtins.match "(([0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4})?::(([0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4})?" a != null
      && n <= 7
    );

  # The relay endpoint must be a literal address, not a hostname: the
  # boot gate's nftables rule holds the address, and resolving a name
  # before the gate is up would need the DNS the gate drops. The IPv6
  # form carries its own brackets.
  parseEndpoint =
    endpoint:
    let
      v6 =
        if lib.hasPrefix "[" endpoint then
          let
            # POSIX extended regexes reject an escaped bracket, hence the
            # stripped "[" and the literal "]"; validV6 does the real
            # check on what the shape leaves.
            m = builtins.match "([0-9A-Fa-f:]+)]:([0-9]+)" (lib.removePrefix "[" endpoint);
          in
          if m != null && validV6 (builtins.elemAt m 0) && validPort (builtins.elemAt m 1) then
            {
              family = 6;
              address = builtins.elemAt m 0;
              port = builtins.elemAt m 1;
              prefixLength = "128";
            }
          else
            null
        else
          null;
      v4 =
        let
          m = builtins.match "([0-9.]+):([0-9]+)" endpoint;
        in
        if m != null && validV4 (builtins.elemAt m 0) && validPort (builtins.elemAt m 1) then
          {
            family = 4;
            address = builtins.elemAt m 0;
            port = builtins.elemAt m 1;
            prefixLength = "32";
          }
        else
          null;
    in
    if v6 != null then v6 else if v4 != null then v4 else null;

  relay =
    if cfg.relay == null || cfg.relay.endpoint == null then null else parseEndpoint cfg.relay.endpoint;

  endpointOk = cfg.relay == null || cfg.relay.endpoint == null || relay != null;

  # The path the install script writes (scripts/nixos-install.sh).
  privateKeyFile =
    if cfg.privateKeyFile != null then cfg.privateKeyFile else "/etc/wireguard/${cfg.interface}.key";

  # The tunnel's default route lives in its own table, and the main
  # table keeps the physical routes. Three rules pick between them, from
  # most to least specific:
  #   32762  the relay's address -> main (the physical link)
  #   32764  anything in main except a default route -> main (the LAN)
  #   32765  everything else -> the tunnel table
  # Without the first rule the relay's own packets would follow the
  # tunnel default and loop; without the second, LAN traffic would too.
  # The first rule also keeps the relay's replies past rp_filter: the
  # source validation of an incoming packet is sent down these rules.
  tunnelTable = 51820;

  setupRules = [
    "# Route the relay's own address, the LAN and everything else"
    "# separately: the relay's packets (and its replies) leave the"
    "# physical link, the LAN stays local, and the rest enters the"
    "# tunnel. See docs/vpn.md."
  ]
  ++
    lib.concatMap
      (family: [
        "ip -${toString family} rule del pref 32762 2>/dev/null || true"
        "ip -${toString family} rule del pref 32764 2>/dev/null || true"
        "ip -${toString family} rule del pref 32765 2>/dev/null || true"
        "ip -${toString family} rule add pref 32764 lookup main suppress_prefixlength 0"
        "ip -${toString family} rule add pref 32765 lookup ${toString tunnelTable}"
      ])
      [
        4
        6
      ]
  ++
    lib.optional (relay != null)
      "ip -${toString relay.family} rule add pref 32762 to ${relay.address}/${relay.prefixLength} lookup main";

  teardownRules =
    lib.concatMap
      (family: [
        "ip -${toString family} rule del pref 32762 2>/dev/null || true"
        "ip -${toString family} rule del pref 32764 2>/dev/null || true"
        "ip -${toString family} rule del pref 32765 2>/dev/null || true"
      ])
      [
        4
        6
      ];

  # What the "accessed but has no value" failure never said.
  missing =
    lib.optional (cfg.address == null) "core.wireguardExit.address"
    ++ lib.optional (cfg.relay == null) "core.wireguardExit.relay"
    ++ lib.optionals (cfg.relay != null && cfg.relay.publicKey == null) [
      "core.wireguardExit.relay.publicKey"
    ]
    ++ lib.optionals (cfg.relay != null && cfg.relay.endpoint == null) [
      "core.wireguardExit.relay.endpoint"
    ];
in
{
  options.core.wireguardExit = {
    enable = lib.mkEnableOption "a full-tunnel WireGuard exit (client side)";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = "Interface name.";
    };

    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.99.99.7/24";
      description = ''
        This machine's address on the tunnel network. The relay's repo
        is the registry of these addresses; give each client its own.
      '';
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      defaultText = lib.literalExpression ''"/etc/wireguard/''${config.core.wireguardExit.interface}.key"'';
      example = "/etc/wireguard/wg0.key";
      description = ''
        Root-only file holding the interface's private key. Defaults to
        `/etc/wireguard/<interface>.key`, where the install script
        writes the key. It must not be in the Nix store.
      '';
    };

    relay = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            publicKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The relay's public key.";
            };

            endpoint = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "203.0.113.10:51820";
              description = ''
                The relay's address and UDP port, as `ip:port` for IPv4
                or `[ip]:port` for IPv6. It must be a literal address:
                the boot gate's nftables rule needs one.
              '';
            };
          };
        }
      );
      default = null;
      description = "The relay this machine exits through.";
    };

    persistentKeepalive = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 25;
      description = ''
        Keepalive interval in seconds (null disables it). A machine
        behind NAT sets this so the tunnel survives until the relay
        speaks next.
      '';
    };

    dns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.99.99.1";
      description = ''
        The relay's resolver address, reachable through the tunnel. When
        set, resolved takes it as its default route for DNS, so lookups
        leave through the tunnel. A search domain the link learned from
        DHCP still claims its own names, and the gate drops those
        queries, so they fail rather than leak. Without it, resolution
        fails: the resolver the link provides is dropped too.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = missing == [ ];
        message = ''
          core.wireguardExit is enabled but these options are unset:
            ${lib.concatStringsSep "\n  " missing}
          A full-tunnel exit needs the machine's tunnel address and the
          relay's public key and endpoint. See docs/vpn.md.
        '';
      }
      {
        assertion = endpointOk;
        message = ''
          core.wireguardExit.relay.endpoint must be "address:port" for
          IPv4 or "[address]:port" for IPv6, with a literal address and a
          port from 1 to 65535. A hostname cannot be used: the boot
          gate's nftables rule holds the address, and resolving a name
          would need the DNS the gate drops. See docs/vpn.md.
        '';
      }
      {
        # A private key in the world-readable store is a leak, and the
        # option is documented as a root-only file.
        assertion = !(lib.hasPrefix "/nix/store/" privateKeyFile);
        message = "core.wireguardExit.privateKeyFile is ${privateKeyFile}, in the Nix store; it must be a root-only file outside it. See docs/vpn.md.";
      }
      {
        # nymvpn and obscura are full tunnels too, and one owns the
        # default route. With both, the exit's gate would not identify
        # the daemon's traffic, so the daemon could never connect.
        assertion = !(config.core.nymvpn.enable || config.core.obscura.enable);
        message = "core.wireguardExit.enable is set with core.nymvpn.enable or core.obscura.enable; one full tunnel owns the default route. See docs/vpn.md.";
      }
    ];

    networking.wireguard.interfaces = lib.mkIf (missing == [ ]) {
      ${cfg.interface} = {
        ips = [ cfg.address ];
        inherit privateKeyFile;
        # The relay's carve-out and the tunnel default route need the
        # policy routing set up in `setupRules`.
        table = toString tunnelTable;
        allowedIPsAsRoutes = true;
        preSetup = setupRules;
        preShutdown = teardownRules;
        peers = [
          {
            publicKey = cfg.relay.publicKey;
            endpoint = cfg.relay.endpoint;
            # A full tunnel: every destination the relay is not itself
            # reached through.
            allowedIPs = [
              "0.0.0.0/0"
              "::/0"
            ];
            inherit (cfg) persistentKeepalive;
          }
        ];
      };
    };

    services.resolved.settings.Resolve = lib.mkIf (cfg.dns != null) {
      DNS = [ cfg.dns ];
      # All domains resolve through the relay's resolver; the per-link
      # servers from DHCP would only be dropped by the gate.
      Domains = [ "~." ];
    };

    ## ----- boot gate -----------------------------------------------------------
    # wg-quick installs no firewall of its own, so the gate is kept for
    # the machine's lifetime rather than lifted once the tunnel is up: a
    # service bound to the physical interface's address then cannot
    # leak. It allows the tunnel interface (WireGuard links are not
    # `oifkind "tun"`), the relay's own address (so the handshake can
    # leave before the tunnel exists), tailscale's carve-outs, the LAN
    # and link scope, and it drops DNS that is not routed through the
    # tunnel. See modules/vpn-gate.nix for the unit, docs/vpn.md for
    # daily use.
    core.internal.egressGates = lib.mkIf (missing == [ ]) {
      "wireguard-exit-gate" = {
        description = "Block network egress while the WireGuard exit tunnel is down";
        hook = "output";
        forward = true;
        forwardRules = [ "oifname \"${cfg.interface}\" accept" ];
        packages = [ pkgs.wireguard-tools ];
        egressRules = [
          "# Tailscale's tunnel device and its marked underlay traffic."
          "meta oifkind \"tun\" accept"
          "meta mark & 0x00ff0000 == 0x00080000 accept"
          "# The relay's own address, so the handshake can leave first."
          "${if relay.family == 6 then "ip6" else "ip"} daddr ${relay.address} udp dport ${relay.port} accept"
          "# Everything else leaves through the tunnel, DNS included."
          "oifname \"${cfg.interface}\" accept"
        ];
        keepTable = true;
        wait = ''
          # The tunnel interface appears later in the boot. A handshake
          # needs the relay to answer; the usual reason one never does is
          # a public key the relay has not registered.
          tries=0
          until wg show ${cfg.interface} latest-handshakes 2>/dev/null | grep -qE '[[:space:]][1-9][0-9]*$'; do
            tries=$((tries + 1))
            if [ "$tries" -ge 36 ]; then
              echo "wireguard-exit-gate: no handshake on ${cfg.interface} after 3 minutes." >&2
              echo "The relay probably has no peer with this machine's public key." >&2
              echo "Register it (docs/vpn.md), then check 'wg show ${cfg.interface}'." >&2
              echo "This machine has no egress through the gate. Lift it for this boot with:" >&2
              echo "  systemctl stop wireguard-exit-gate" >&2
              break
            fi
            sleep 5
          done
        '';
      };
    };
  };
}
