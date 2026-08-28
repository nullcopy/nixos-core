{
  config,
  lib,
  pkgs,
  ...
}:

# Machine-wide tailscale, up ONLY while the admin user is logged in.
#
# The daemon (tailscaled) always runs, but it holds no tunnel on its own.
# `tailscale-connect@<uid>` is bound to systemd's per-user manager
# (`user@<uid>.service`, which starts at that user's first login — console,
# greeter, or ssh — and stops when their last session ends): the instance
# for core.tailscale.user brings the tailnet up on login and takes it down
# on logout. Instances for every other user exit immediately, so other
# accounts neither get nor need tailscale.
#
# No exit node, ever: only tailnet destinations (100.64.0.0/10 and MagicDNS
# names) ride tailscale; everything else follows the normal default route,
# which is NymVPN's tunnel when core.nymvpn.enable is on. VPN membership is
# machine config, not user config — user dotfiles contain no tailscale.
#
# Which tailnet (and any keys) deliberately live OUTSIDE the repo and the
# nix store: values in the repo would publish with it, and values in the
# config would be baked into world-readable /nix/store paths. Instead they
# sit in a root-owned env file, read at service start. systemd's
# EnvironmentFile parser does NOT strip trailing comments, so keep the
# file to bare KEY=VALUE lines:
#
#   sudo install -d -m 700 /etc/tailscale
#   sudo tee /etc/tailscale/connect.env >/dev/null <<'EOF'
#   TAILSCALE_LOGIN_SERVER=https://your.headscale.example
#   EOF
#   sudo chmod 600 /etc/tailscale/connect.env
#
# Optional extra line: TAILSCALE_AUTH_KEY=tskey-auth-... for unattended
# first enrollment. Without it, enroll once interactively after first boot:
#   sudo tailscale up --login-server=<server>
# tailscaled persists its state in /var/lib/tailscale, so from then on the
# connect service just re-asserts policy (idempotent, near-instant).
let
  cfg = config.core.tailscale;
  # Same build as the daemon, so CLI and daemon never disagree.
  tailscale = lib.getExe config.services.tailscale.package;
in
{
  options.core.tailscale = {
    enable = lib.mkEnableOption "tailscale daemon, connected only while core.tailscale.user is logged in";

    user = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = ''
        The admin account whose login session brings the tailnet up and
        whose logout takes it down. Must be one of users.users.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/tailscale/connect.env";
      description = ''
        Root-owned env file (0600) providing TAILSCALE_LOGIN_SERVER and
        optionally TAILSCALE_AUTH_KEY. Kept out of the repo and the nix
        store on purpose. If the file is missing, the connect service
        logs and does nothing.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasAttr cfg.user config.users.users;
        message = "core.tailscale.user = \"${cfg.user}\" is not declared in users.users.";
      }
    ];

    services.tailscale.enable = true;

    # Per-user-manager instance; %i is the numeric uid (user@.service's
    # instance name). The uid -> name lookup happens at runtime, so the
    # admin's uid does not need to be fixed in the config.
    systemd.services."tailscale-connect@" = {
      description = "Tailscale tunnel for the login session of uid %i";
      bindsTo = [ "user@%i.service" ];
      after = [
        "user@%i.service"
        "tailscaled.service"
      ];
      requires = [ "tailscaled.service" ];
      environment.TAILSCALE_SESSION_UID = "%i";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # "-" prefix: a missing file is not an error (machine not set up yet)
        EnvironmentFile = "-${cfg.environmentFile}";
      };
      # --reset: the env file IS the policy. Without it, `tailscale up`
      # refuses to run whenever a previously set non-default pref is not
      # repeated on the command line, so the unit would fail on every
      # login after any interactive tweak.
      # --timeout: an unenrolled machine (no auth key) prints an auth URL
      # and would otherwise wait forever.
      script = ''
        if [ "$(id -un "$TAILSCALE_SESSION_UID")" != ${lib.escapeShellArg cfg.user} ]; then
          exit 0
        fi
        if [ -z "''${TAILSCALE_LOGIN_SERVER:-}" ]; then
          echo "no TAILSCALE_LOGIN_SERVER in ${cfg.environmentFile}; not connecting" >&2
          exit 0
        fi
        exec ${tailscale} up --reset --timeout 30s \
          --login-server="$TAILSCALE_LOGIN_SERVER" \
          ''${TAILSCALE_AUTH_KEY:+--auth-key="$TAILSCALE_AUTH_KEY"}
      '';
      preStop = ''
        if [ "$(id -un "$TAILSCALE_SESSION_UID")" = ${lib.escapeShellArg cfg.user} ]; then
          ${tailscale} down
        fi
      '';
    };

    # Drop-in on systemd's user@.service template: every user manager pulls
    # in its own tailscale-connect instance (which is a no-op for everyone
    # but core.tailscale.user).
    systemd.services."user@".wants = [ "tailscale-connect@%i.service" ];
  };
}
