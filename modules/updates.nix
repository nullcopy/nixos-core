{
  config,
  lib,
  pkgs,
  ...
}:

# A daily background fetch of what `nix flake update && nixos-rebuild
# switch` would download, so the switch finds nearly all of it in the
# store. See ../docs/updates.md.
let
  cfg = config.core.updates.fetch;

  nix = "nix --max-jobs ${toString cfg.maxJobs} --cores ${toString cfg.cores}";

  # The updated lock goes to the runtime dir, not over the machine
  # repo's flake.lock: the fetch changes nothing in the working tree.
  lock = "/run/nixos-fetch/flake.lock";

  # Out-links under the state dir are GC roots (nix build registers
  # them), so what was fetched survives nix.gc until the next fetch
  # replaces it.
  state = "/var/lib/nixos-fetch";

  lockFlags = "--reference-lock-file ${lock} --no-write-lock-file";

  # Exit status of a failed `nix flake update`, the step that fails when
  # the network does. Only this status is retried.
  tempfail = 75;

  wheelUsers = lib.attrNames (
    lib.filterAttrs (_: user: user.isNormalUser && lib.elem "wheel" user.extraGroups) config.users.users
  );
in
{
  options.core.updates.fetch = {
    enable = lib.mkEnableOption "daily background fetch of the newest inputs' system generation";

    flake = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = ''
        Absolute path of the machine repo the fetch updates and builds:
        a local checkout, not a flake reference.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = if lib.length wheelUsers == 1 then lib.head wheelUsers else "root";
      defaultText = lib.literalMD "the machine's only normal user in `wheel`, else `root`";
      description = ''
        The user the fetch runs as: the owner of `flake`, normally the
        admin. Inputs that need credentials (a private repo, `git+ssh`)
        are fetched with this user's SSH keys and nix.conf, which root
        does not have.
      '';
    };

    configName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = ''
        The `nixosConfigurations` attribute the fetch builds. The default
        holds when the attribute is named after the hostname, as
        `nixos-rebuild` also expects.
      '';
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "When the fetch runs, as a systemd OnCalendar expression.";
    };

    maxJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Derivations the fetch builds at once. Nearly everything comes
        from the binary cache; the cap matters for what does not.
      '';
    };

    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Cores each derivation the fetch builds may use.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.flake;
        message = "core.updates.fetch.flake must be the absolute path of a local checkout, not a flake reference: ${cfg.flake}";
      }
    ];

    systemd.services.nixos-fetch = {
      description = "Fetch the system generation of the newest inputs";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig = {
        ConditionPathExists = "${cfg.flake}/flake.nix";
        # Skip the run on battery; Persistent= on the timer does not
        # bring it back, the next day's run does.
        ConditionACPower = true;
        # A failed fetch is tried again twice. The limit counts every
        # start in the interval, a manual one included, and the interval
        # is over before the timer's next run.
        StartLimitIntervalSec = "6h";
        StartLimitBurst = 3;
      };
      path = [
        config.nix.package
        pkgs.jq
      ];
      # Builds go through nix-daemon, whose cgroup carries base.nix's
      # MemoryMax. For a user other than root that is already the case.
      environment.NIX_REMOTE = "daemon";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        RuntimeDirectory = "nixos-fetch";
        StateDirectory = "nixos-fetch";
        Nice = 19;
        IOSchedulingClass = "idle";
        # The evaluation runs in this unit, outside the daemon's cgroup.
        MemoryMax = lib.mkDefault "30%";
        # Only a failed fetch, likely the network, is tried again. An
        # evaluation or build error recurs on every try.
        RestartForceExitStatus = tempfail;
        RestartSec = "30min";
      };
      script = ''
        set -euo pipefail

        ${nix} flake update --flake '${cfg.flake}' --output-lock-file ${lock} \
          || exit ${toString tempfail}

        ${nix} build ${lockFlags} \
          '${cfg.flake}#nixosConfigurations."${cfg.configName}".config.system.build.toplevel' \
          --out-link ${state}/system

        # The source tree of every input, which no closure includes: the
        # switch evaluates from them. Out-links are rooted by path, so
        # each run roots its set in a new directory (input, input-1, ...)
        # and removes the older sets only once that succeeded.
        archive=$(${nix} flake archive --json ${lockFlags} '${cfg.flake}')
        mapfile -t inputs < <(jq -r '[.. | .path? // empty] | unique | .[]' <<<"$archive")
        new=${state}/inputs.$(date +%s)
        mkdir "$new"
        ${nix} build "''${inputs[@]}" --out-link "$new/input"
        for old in ${state}/inputs*; do
          [ "$old" = "$new" ] || rm -rf "$old"
        done
      '';
    };

    systemd.timers.nixos-fetch = {
      description = "Fetch the system generation of the newest inputs";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        # A run missed while the machine was off happens at next boot.
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
