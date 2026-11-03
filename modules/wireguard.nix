{
  config,
  lib,
  pkgs,
  ...
}:

# A static WireGuard tunnel to a relay. The interface's own address can
# carry any prefix, but every peer's AllowedIPs must be a host route
# (/32 or /128): a wider range adds policy-routing problems and gives
# the other end access it must not have. The private key is a root-only
# file, never in the store.
let
  cfg = config.core.wireguard;

  # A host route is /32 for IPv4 and /128 for IPv6. The suffix alone is
  # not enough: "2001:db8::/32" and "10.0.0.1/128" both end in a
  # host-route suffix, but the first is a network and the second an
  # invalid IPv4 prefix.
  isHostRoute =
    a:
    let
      parts = lib.splitString "/" a;
      addr = lib.head parts;
      prefix = lib.elemAt parts 1;
    in
    lib.length parts == 2 && (if lib.hasInfix ":" addr then prefix == "128" else prefix == "32");

  hostRoutes = lib.all (peer: lib.all isHostRoute peer.allowedIPs) cfg.peers;
in
{
  options.core.wireguard = {
    enable = lib.mkEnableOption "a static WireGuard tunnel";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = "Interface name.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      example = "10.99.99.2/24";
      description = ''
        The interface's own address. Its prefix length is unrelated to
        the peers' AllowedIPs and may be a /24.
      '';
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      example = "/etc/wireguard/wg0.key";
      description = ''
        Root-only file holding the interface's private key. It must not
        be in the Nix store.
      '';
    };

    peers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            publicKey = lib.mkOption {
              type = lib.types.str;
              description = "The peer's public key.";
            };

            endpoint = lib.mkOption {
              type = lib.types.str;
              example = "203.0.113.10:51821";
              description = "The peer's public address and UDP port.";
            };

            allowedIPs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              example = [ "10.99.99.1/32" ];
              description = "Host routes to this peer; /32 or /128 only.";
            };

            persistentKeepalive = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = 25;
              description = ''
                Keepalive interval in seconds (null disables it). A
                machine behind NAT sets this so the tunnel survives
                until the relay speaks next.
              '';
            };
          };
        }
      );
      default = [ ];
      description = "Peers on the tunnel.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hostRoutes;
        message = ''
          core.wireguard: every peer's AllowedIPs must be a host route
          (/32 or /128). A wider range adds policy-routing problems and
          gives the other end access it must not have. For a range that
          is genuinely wanted, set networking.wireguard.interfaces
          directly instead of core.wireguard.
        '';
      }
    ];

    networking.wireguard.interfaces.${cfg.interface} = {
      ips = [ cfg.address ];
      inherit (cfg) privateKeyFile peers;
    };
  };
}
