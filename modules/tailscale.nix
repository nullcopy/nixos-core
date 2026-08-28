{
  config,
  lib,
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
  };
}
