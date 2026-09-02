{
  config,
  lib,
  pkgs,
  ...
}:

# Tailscale daemon. The admin connects with `sudo tailscale up
# --login-server=...` and disconnects with `sudo tailscale down`.
# Tailnet destinations only; all other traffic uses the default route
# (NymVPN).
{
  options.core.tailscale.enable = lib.mkEnableOption "tailscale daemon (manual `sudo tailscale up`)";

  config = lib.mkIf config.core.tailscale.enable {
    services.tailscale.enable = true;

    # nym-vpnd's firewall accepts only flows that carry its bypass marks;
    # this applies them to tailnet traffic (the subnet form of nym's
    # split-tunnel). The 0x14d/0xf42 constants are nym-internal and can
    # change in a nym release; the failure mode is blocked tailnet
    # traffic.
    systemd.services.tailscale-nym-bridge = lib.mkIf config.core.nymvpn.enable {
      description = "Pass tailnet traffic through the NymVPN firewall";
      after = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "${pkgs.nftables}/bin/nft delete table inet tailscale-nym";
      };
      script = ''
        ${pkgs.nftables}/bin/nft -f - <<'EOF'
        table inet tailscale-nym { }
        delete table inet tailscale-nym
        table inet tailscale-nym {
          chain out {
            type route hook output priority -151;
            ip daddr 100.64.0.0/10 meta mark set 0x14d
          }
          chain in {
            type filter hook prerouting priority -200;
            iifname "tailscale0" ct mark set 0xf42
          }
        }
        EOF
      '';
    };
  };
}
