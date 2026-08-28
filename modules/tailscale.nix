{
  config,
  lib,
  ...
}:

# Tailscale daemon only. Nothing connects automatically: the admin brings
# the tailnet up and down by hand, and it stays down otherwise.
#
#   sudo tailscale up --login-server=https://your.headscale.example
#   sudo tailscale down
#
# tailscaled persists its enrollment in /var/lib/tailscale, so after the
# first `up` (which prints an auth URL, or takes --auth-key) later ones
# need no login. Never pass --exit-node: only tailnet destinations
# (100.64.0.0/10, MagicDNS names) should ride tailscale; everything else
# follows the default route, which is NymVPN's tunnel when
# core.nymvpn.enable is on. Other users need nothing from tailscale and
# cannot control it (the daemon requires root or its operator).
{
  options.core.tailscale.enable = lib.mkEnableOption "tailscale daemon (manual `sudo tailscale up`)";

  config = lib.mkIf config.core.tailscale.enable {
    services.tailscale.enable = true;
  };
}
