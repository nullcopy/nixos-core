{
  config,
  lib,
  pkgs,
  ...
}:

# TLS termination for a machine that receives forwarded :80/:443 from a
# relay — a public VPS doing SNI passthrough, say. Caddy holds the
# certificates, gets them from Let's Encrypt over ACME HTTP-01, and
# reverse proxies each vhost to a loopback upstream. Caddy is never
# exposed directly: :80 and :443 are opened only on the interfaces
# named in core.caddy.openFirewallInterfaces (the relay's tunnel, the
# tailnet).
let
  cfg = config.core.caddy;
in
{
  options.core.caddy = {
    enable = lib.mkEnableOption "Caddy as the machine's TLS terminator";

    email = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "admin@example.net";
      description = ''
        ACME account contact. Recommended: without it, an expiring
        certificate cannot be recovered.
      '';
    };

    acmeCA = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://acme-staging-v02.api.letsencrypt.org/directory";
      description = ''
        Override the ACME directory. The default (null) lets Caddy use
        its production issuers; point it at a staging endpoint while
        testing, to avoid rate limits.
      '';
    };

    virtualHosts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            upstream = lib.mkOption {
              type = lib.types.str;
              example = "127.0.0.1:8080";
              description = "Address Caddy reverse proxies this hostname to.";
            };

            extraConfig = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = "Extra Caddyfile directives for this vhost, after the reverse_proxy.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          "cloud.example.net".upstream = "127.0.0.1:11000";
          "pics.example.net".upstream = "127.0.0.1:2283";
        }
      '';
      description = ''
        Hostnames to terminate TLS for, each with the loopback upstream
        behind it. Caddy requests a certificate for every name here.
      '';
    };

    openFirewallInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "wg0"
        "tailscale0"
      ];
      description = ''
        Interfaces on which :80 and :443 are opened. The relay's tunnel
        is the usual one; the tailnet is a reasonable second. Nothing is
        opened on the LAN or WAN, so Caddy is reachable only through
        them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      inherit (cfg) email acmeCA;
      # Caddy's admin API listens on localhost:2019 with no
      # authentication, so any local user can reconfigure the proxy. It
      # exists for `caddy reload`; restart on a config change instead and
      # turn it off. A machine that wants reloading sets
      # services.caddy.enableReload = true, which drops the `admin off`.
      enableReload = lib.mkDefault false;
      globalConfig = lib.mkIf (!config.services.caddy.enableReload) "admin off";
      virtualHosts = lib.mapAttrs (name: vh: {
        extraConfig = ''
          reverse_proxy ${vh.upstream}
          ${vh.extraConfig}
        '';
      }) cfg.virtualHosts;
    };

    networking.firewall.interfaces = lib.genAttrs cfg.openFirewallInterfaces (_: {
      allowedTCPPorts = [
        80
        443
      ];
      # UDP/443 carries HTTP/3, which Caddy serves by default; its own
      # firewall integration opens it alongside TCP.
      allowedUDPPorts = [ 443 ];
    });
  };
}
