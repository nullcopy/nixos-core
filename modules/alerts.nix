{
  config,
  lib,
  pkgs,
  ...
}:

# One place to send an alert from. core.alerts.command is a program
# that gets the alert's title as its argument and the body on stdin;
# nothing is sent until a machine sets it. The ZFS and backup modules
# use it for failed units, stale backups and pool events.
let
  cfg = config.core.alerts;

  # `alert-send TITLE < BODY`, for units and scripts.
  alertSend = pkgs.writeShellScriptBin "alert-send" ''
    set -euo pipefail
    title="$(${pkgs.inetutils}/bin/hostname): ''${1:?alert-send TITLE}"
    ${
      if cfg.command == null then
        ''
          echo "core.alerts.command is unset; dropping alert: $title" >&2
          cat >/dev/null
        ''
      else
        ''
          export ALERT_TITLE="$title"
          set -- "$title"
          exec ${cfg.command}
        ''
    }
  '';
in
{
  options.core.alerts = {
    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = ''''${pkgs.curl}/bin/curl -fsS -H "Title: $1" -H "Authorization: Bearer $(cat /etc/alerts/ntfy-token)" --data-binary @- https://ntfy.example.net/machines'';
      description = ''
        Shell command that delivers an alert: it gets the title,
        prefixed with the hostname, as $1 and in $ALERT_TITLE, and the
        body on stdin. Unset,
        alerts go to the journal only. Keep secrets in a root-only
        file the command reads, not in this option, which ends up in
        the world-readable store.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = alertSend;
      readOnly = true;
      description = "`alert-send TITLE` reading the body on stdin; what the other modules run.";
    };

    onFailure = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "syncoid-tank-encrypted-obelisk" ];
      description = ''
        Units (names without .service) whose failure sends an alert
        with the unit's last journal lines. The ZFS and backup modules
        add theirs. The unit must exist: a name that matches nothing
        creates a unit with only OnFailure=, which systemd refuses to
        load.
      '';
    };
  };

  config = {
    environment.systemPackages = [ alertSend ];

    systemd.services = {
      # alert@<unit>.service: the body is that unit's recent journal.
      "alert@" = {
        description = "Send an alert about the failure of %i";
        scriptArgs = "%i";
        script = ''
          unit=$1
          ${pkgs.systemd}/bin/journalctl -u "$unit" -n 40 --no-pager -o short-iso \
            | ${alertSend}/bin/alert-send "$unit failed"
        '';
        serviceConfig.Type = "oneshot";
      };
    }
    // lib.genAttrs cfg.onFailure (unit: {
      onFailure = [ "alert@${unit}.service" ];
    });
  };
}
