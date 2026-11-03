{
  config,
  lib,
  pkgs,
  ...
}:

# The headscale control server for a personal tailnet. It binds
# loopback, so a terminator (core.caddy, usually) fronts it at
# core.headscale.serverUrl. The database and keys live under
# core.headscale.dataDir, which belongs on an encrypted dataset so
# snapshots and replication cover the tailnet's identity.
#
# DNS and DERP choices are not wrapped here; a machine sets
# services.headscale.settings.dns.* and .derp.* directly, and they merge
# with the values below.
let
  cfg = config.core.headscale;
in
{
  options.core.headscale = {
    enable = lib.mkEnableOption "the headscale control server";

    serverUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://hs.example.net";
      description = "The URL tailnet clients connect to; the terminator's vhost for this server.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/headscale";
      example = "/tank/encrypted/headscale";
      description = ''
        Holds db.sqlite and the noise and DERP private keys. On an
        encrypted dataset it rides along with snapshots and
        replication; at the default it lives on the root.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback port the server listens on.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.headscale = {
          enable = true;
          address = "127.0.0.1";
          inherit (cfg) port;
          settings.server_url = cfg.serverUrl;
          settings.database.sqlite.path = "${cfg.dataDir}/db.sqlite";
          settings.noise.private_key_path = "${cfg.dataDir}/noise_private.key";
          settings.derp.server.private_key_path = "${cfg.dataDir}/derp_server_private.key";
        };
      }

      # MagicDNS needs a base_domain, and overriding the clients' DNS
      # needs nameservers; both are machine policy, so they stay off by
      # default (nixpkgs asserts on them). Set the same options normally
      # to turn them on. These are separate definitions so the mkDefault
      # is honored: nested inside the attribute set above, it would not be.
      {
        services.headscale.settings.dns.magic_dns = lib.mkDefault false;
        services.headscale.settings.dns.override_local_dns = lib.mkDefault false;
      }

      # The directory must exist before the server starts. On a data
      # dataset it has to be created after that dataset is mounted;
      # systemd-tmpfiles-setup runs after local-fs.target, so it lands on
      # the mount, not on the root.
      {
        systemd.tmpfiles.rules = [
          "d ${cfg.dataDir} 0750 headscale headscale - -"
        ];
        # The upstream unit sets ProtectSystem = "strict", which makes
        # the whole filesystem read-only except StateDirectory
        # (/var/lib/headscale). A custom dataDir has to be writable or
        # headscale cannot create its database and keys.
        systemd.services.headscale.serviceConfig.ReadWritePaths = [ cfg.dataDir ];
      }
    ]
  );
}
