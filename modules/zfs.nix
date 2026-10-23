{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

# ZFS support: kernel module and tools, pool import at boot, key
# loading, scrubs, pool-event alerts, and the `core-zpool` wizard that
# creates a data pool in the layout docs/backup.md describes. The
# hostId is derived from the hostname, so a reinstalled machine
# imports its old pools without -f and nothing per machine needs to
# be remembered.
let
  cfg = config.core.zfs;
  zfs = config.boot.zfs.package;

  # The mount units of the fileSystems entries on a dataset (legacy
  # mountpoints, as the install script creates). A dataset mounted by
  # its own mountpoint property is handled by zfs-mount.service.
  mountUnitsOf =
    ds:
    map (fs: "${utils.escapeSystemdPath fs.mountPoint}.mount") (
      lib.filter (fs: fs.fsType == "zfs" && fs.device == ds) (lib.attrValues config.fileSystems)
    );

  loadKeyService =
    ds:
    lib.nameValuePair "zfs-load-key-${utils.escapeSystemdPath ds}" {
      description = "Load the encryption key of ${ds}";
      # Pools are imported by then; the key file is on the root, which
      # is mounted. Everything that mounts the dataset waits for this.
      after = [ "zfs-import.target" ];
      wants = [ "zfs-import.target" ];
      before = [
        "zfs-mount.service"
        "zfs.target"
      ]
      ++ mountUnitsOf ds;
      wantedBy = [ "zfs.target" ];
      requiredBy = mountUnitsOf ds;
      unitConfig.DefaultDependencies = false;
      path = [ zfs ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ "$(zfs get -H -o value keystatus ${lib.escapeShellArg ds})" != available ]; then
          zfs load-key ${lib.escapeShellArg ds}
        fi
      '';
    };

  zpoolWizard = pkgs.writeShellApplication {
    name = "core-zpool";
    runtimeInputs = [
      zfs
      pkgs.gptfdisk
      pkgs.util-linux
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
    ];
    text = builtins.readFile ../scripts/zpool-wizard.sh;
  };
in
{
  options.core.zfs = {
    enable = lib.mkEnableOption "ZFS: kernel module, tools, pool import at boot, scrubs";

    pools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tank" ];
      description = ''
        Pools imported at boot besides those that `fileSystems` needs.
        A pool with nothing to mount (a backup receiver's, whose
        datasets stay locked) must be listed here or it is not
        imported.
      '';
    };

    unlock = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "rpool/home"
        "tank/local"
      ];
      description = ''
        Encrypted datasets whose keys are loaded after the pools are
        imported, before anything mounts them. Their keylocation is a
        file on the (LUKS-encrypted) root under /etc/zfs/keys, which
        is why this happens in stage 2 and not in the initrd, where
        that file is not there yet. Nothing else is unlocked: datasets
        received from backup peers carry a key this machine does not
        have, and the NixOS default of unlocking everything at import
        would stop at a prompt for it.
      '';
    };

    scrubInterval = lib.mkOption {
      type = lib.types.str;
      default = "monthly";
      description = "systemd calendar expression; every imported pool is scrubbed on it.";
    };
  };

  config = lib.mkIf cfg.enable {
    # nixpkgs' zfs is built against the default (LTS) kernel and the
    # build fails loudly if a machine picks a kernel ZFS does not
    # support yet, so a `boot.kernelPackages = linuxPackages_latest`
    # override may have to wait for ZFS.
    boot.supportedFilesystems.zfs = true;
    boot.zfs.forceImportRoot = false;
    boot.zfs.extraPools = cfg.pools;
    # Keys are loaded by the services below, not at import.
    boot.zfs.requestEncryptionCredentials = [ ];

    # ZFS refuses to import a pool last used by another hostId. A hash
    # of the hostname is stable across reinstalls and needs no record.
    networking.hostId = lib.mkDefault (
      builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName)
    );

    systemd.services = lib.listToAttrs (map loadKeyService cfg.unlock);

    services.zfs.autoScrub = {
      enable = true;
      interval = cfg.scrubInterval;
    };

    environment.systemPackages = [ zpoolWizard ];

    core.alerts.onFailure = [
      "zfs-scrub"
    ]
    ++ map (ds: "zfs-load-key-${utils.escapeSystemdPath ds}") cfg.unlock;
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
          data|deadman)
            # Data errors arrive in bursts; one alert per pool per hour.
            zed_rate_limit "$ZEVENT_POOL;$ZEVENT_SUBCLASS;core-alert" 3600 || exit 0
            $zpool status "$ZEVENT_POOL" | send "pool $ZEVENT_POOL: $ZEVENT_SUBCLASS event" ;;
        esac
        exit 0
      '';
    };
  };
}
