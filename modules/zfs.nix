{
  config,
  lib,
  pkgs,
  ...
}:

# ZFS support for data pools on attached drives: kernel module and
# tools, pool import at boot, key loading, scrubs, pool-event alerts.
# The root stays on btrfs; nothing here touches the install layout.
# docs/zfs.md has how pools and keys are handled, and `core-zpool`
# creates a pool.
let
  cfg = config.core.zfs;

  derivedHostId = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

  zpoolWizard = pkgs.writeShellApplication {
    name = "core-zpool";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.gptfdisk
      pkgs.util-linux
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.systemd
    ];
    text = builtins.readFile ../scripts/zpool-wizard.sh;
  };
in
{
  options.core.zfs = {
    enable = lib.mkEnableOption "ZFS: kernel module, tools, pool import at boot, key loading, scrubs";

    pools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tank" ];
      description = ''
        Pools imported at boot. A pool with nothing to mount (one that
        holds only datasets whose keys this machine does not have, say)
        must be listed here or it is not imported.
      '';
    };

    unlock = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tank/encrypted" ];
      description = ''
        Encryption roots whose keys are loaded when their pool is
        imported, from their keylocation: a passphrase file under
        /etc/zfs/keys on the (LUKS-encrypted) root. Datasets that
        inherit the key are unlocked with their root. Nothing else is
        unlocked, so a dataset whose key is not on this machine (a
        raw-received backup) does not stop the boot at a prompt. A key
        that fails to load fails the pool's zfs-import-<pool> unit;
        the pool stays imported and the dataset stays unmounted.
      '';
    };

    scrubInterval = lib.mkOption {
      type = lib.types.str;
      default = "monthly";
      description = "systemd calendar expression; every imported pool is scrubbed on it.";
    };

    arcMaxPercent = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 1 100);
      default = 25;
      description = ''
        Cap on the ARC, ZFS's read cache, as a percentage of RAM; null
        keeps ZFS's own default (half of RAM or more). The ARC is not
        page cache and gives memory back slowly under pressure, so an
        uncapped one works against the memory guardrails in base.nix.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # nixpkgs loads keys only inside zfs-import-<pool>, which exists
        # only for pools it imports; an unlock entry for any other pool
        # is silently never loaded.
        assertion = lib.all (root: lib.elem (lib.head (lib.splitString "/" root)) cfg.pools) cfg.unlock;
        message = "core.zfs.unlock: every encryption root's pool must be in core.zfs.pools, or its key is never loaded.";
      }
      {
        # The derived hostId is only as unique as the hostname.
        assertion =
          config.networking.hostId != derivedHostId
          || !lib.elem config.networking.hostName [
            ""
            "nixos"
            "MYHOSTNAME"
          ];
        message = "core.zfs derives networking.hostId from networking.hostName, which is unset or a placeholder (\"${config.networking.hostName}\"); set a unique hostName, or networking.hostId.";
      }
    ];

    # nixpkgs' zfs is built against the default (LTS) kernel and the
    # build fails loudly if a machine picks a kernel ZFS does not
    # support yet, so a `boot.kernelPackages = linuxPackages_latest`
    # override may have to wait for ZFS.
    boot.supportedFilesystems.zfs = true;
    boot.zfs.extraPools = cfg.pools;
    # mkDefault so a machine can still set the option itself (to true,
    # say) without mkForce; the bool form does not merge with a list.
    boot.zfs.requestEncryptionCredentials = lib.mkDefault cfg.unlock;
    # Only root pools are affected and the root is not on ZFS, but
    # nixpkgs warns until the option is set (its default is true before
    # stateVersion 26.11).
    boot.zfs.forceImportRoot = lib.mkDefault false;

    # ZFS refuses to import a pool last used by another hostId. A hash
    # of the hostname is stable across reinstalls and needs no record.
    # A renamed machine imports its pools once with `zpool import -f`,
    # or pins the old value here.
    networking.hostId = lib.mkDefault derivedHostId;

    # zfs_arc_max is in bytes and RAM is known only at runtime, so the
    # cap is set once the module is loaded (boot.kernelModules has zfs)
    # and before pools are imported.
    systemd.services.zfs-arc-max = lib.mkIf (cfg.arcMaxPercent != null) {
      description = "Cap the ZFS ARC at ${toString cfg.arcMaxPercent}% of RAM";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      before = [ "zfs-import.target" ];
      unitConfig.ConditionPathExists = "/sys/module/zfs/parameters/zfs_arc_max";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        kb=$(${pkgs.gawk}/bin/awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
        echo $((kb * 1024 * ${toString cfg.arcMaxPercent} / 100)) >/sys/module/zfs/parameters/zfs_arc_max
      '';
    };

    services.zfs.autoScrub = {
      enable = lib.mkDefault true;
      interval = cfg.scrubInterval;
    };

    environment.systemPackages = [ zpoolWizard ];

    core.alerts.onFailure = [
      "zfs-scrub"
    ]
    # The pools' import units, which also load the keys.
    ++ map (pool: "zfs-import-${pool}") cfg.pools;

    # Pool events go to core.alerts.command. ZED runs every all-*.sh
    # zedlet for every event; this one picks the ones that matter.
    environment.etc."zfs/zed.d/all-core-alert.sh" = {
      mode = "0555";
      text = ''
        #!${pkgs.runtimeShell}
        # shellcheck disable=SC1091
        . "''${ZED_ZEDLET_DIR}/zed-functions.sh"
        send() { ${config.core.alerts.package}/bin/alert-send "$1"; }
        zpool=${config.boot.zfs.package}/bin/zpool
        case "$ZEVENT_SUBCLASS" in
          statechange)
            case "$ZEVENT_VDEV_STATE_STR" in
              DEGRADED|FAULTED|REMOVED|UNAVAIL)
                $zpool status "$ZEVENT_POOL" | send "pool $ZEVENT_POOL: vdev $ZEVENT_VDEV_PATH $ZEVENT_VDEV_STATE_STR" ;;
            esac ;;
          scrub_finish|resilver_finish)
            if ! $zpool status -x "$ZEVENT_POOL" | ${pkgs.gnugrep}/bin/grep -q "is healthy"; then
              $zpool status "$ZEVENT_POOL" | send "pool $ZEVENT_POOL: $ZEVENT_SUBCLASS with errors"
            fi ;;
          data)
            # Data errors arrive in bursts; one alert per pool per hour.
            zed_rate_limit "$ZEVENT_POOL;$ZEVENT_SUBCLASS;core-alert" 3600 || exit 0
            $zpool status "$ZEVENT_POOL" | send "pool $ZEVENT_POOL: data error" ;;
          deadman)
            # A hung I/O; `zpool status` could hang too, so no status.
            zed_rate_limit "$ZEVENT_POOL;$ZEVENT_SUBCLASS;core-alert" 3600 || exit 0
            echo "vdev $ZEVENT_VDEV_PATH" | send "pool $ZEVENT_POOL: deadman (hung I/O)" ;;
        esac
        exit 0
      '';
    };
  };
}
