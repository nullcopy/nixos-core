{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

# ZFS support: kernel module and tools, pool import at boot, key
# loading, scrubs. The hostId defaults to a hash of the hostname; the
# install script pins it in hardware-configuration.nix, so a renamed or
# reinstalled machine imports its old pools without -f. docs/zfs.md has the layout the
# install script creates and how keys are handled.
let
  cfg = config.core.zfs;
  zfs = config.boot.zfs.package;

  # The mount units of the fileSystems entries on a dataset or a
  # dataset under it (legacy mountpoints, as the install script
  # creates), so an encryption root that is never mounted itself still
  # holds back the mounts of its children. A dataset mounted by its own
  # mountpoint property is handled by zfs-mount.service.
  mountUnitsOf =
    ds:
    map (fs: "${utils.escapeSystemdPath fs.mountPoint}.mount") (
      lib.filter (fs: fs.fsType == "zfs" && (fs.device == ds || lib.hasPrefix "${ds}/" fs.device)) (
        lib.attrValues config.fileSystems
      )
    );

  # Pools the initrd imports (they hold a filesystem needed for boot).
  # A dataset on one of them is importable from the start of stage 2
  # and need not wait for zfs-import.target, which also waits for the
  # data pools and their import timeouts.
  poolOf = ds: lib.head (lib.splitString "/" ds);
  rootPools = lib.unique (
    map (fs: poolOf fs.device) (
      lib.filter (fs: fs.fsType == "zfs" && utils.fsNeededForBoot fs) (lib.attrValues config.fileSystems)
    )
  );

  # The core- prefix keeps clear of the zfs-load-key-* units that
  # OpenZFS's zfs-mount-generator emits when the zfs-list cache is on.
  loadKeyService =
    ds:
    let
      mounts = mountUnitsOf ds;
      importUnit = lib.optional (!lib.elem (poolOf ds) rootPools) "zfs-import.target";
    in
    lib.nameValuePair "core-zfs-load-key-${utils.escapeSystemdPath ds}" {
      description = "Load the encryption key of ${ds}";
      # Pools are imported by then; the key file is on the root, which
      # is mounted. Everything that mounts the dataset, or one under
      # it, waits for this.
      # A missing or wrong key file for a dataset in fileSystems fails
      # that mount, and with it the boot (emergency mode).
      after = importUnit;
      wants = importUnit;
      before = [
        "zfs-mount.service"
        "zfs.target"
      ]
      ++ mounts;
      wantedBy = [ "zfs.target" ];
      requiredBy = mounts;
      unitConfig.DefaultDependencies = false;
      path = [ zfs ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # The key belongs to the encryption root: the dataset itself or a
      # parent. An unencrypted dataset has none ("-") and is left alone.
      script = ''
        root=$(zfs get -H -o value encryptionroot ${lib.escapeShellArg ds})
        if [ "$root" = - ]; then
          echo ${lib.escapeShellArg "${ds} is not encrypted"}
        elif [ "$(zfs get -H -o value keystatus "$root")" != available ]; then
          zfs load-key "$root"
        fi
      '';
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
        A pool with nothing to mount (one that holds only datasets
        whose keys this machine does not have, say) must be listed here
        or it is not imported.
      '';
    };

    unlock = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "rpool/encrypted"
        "tank/local"
      ];
      description = ''
        Encrypted datasets whose keys are loaded after the pools are
        imported, before anything mounts them or a dataset under them;
        an encryption root covers every dataset that inherits its key. Their keylocation is a
        file on the (LUKS-encrypted) root under /etc/zfs/keys, which
        is why this happens in stage 2 and not in the initrd, where
        that file is not there yet. Nothing else is unlocked: the NixOS
        default of unlocking every encrypted dataset at import stops at
        a prompt for any dataset whose key is not on this machine (a
        raw-received backup, for instance).
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
    boot.zfs.forceImportRoot = lib.mkDefault false;
    boot.zfs.extraPools = cfg.pools;
    # Keys are loaded by the services below, not at import. A machine
    # can still name datasets to prompt for at import.
    boot.zfs.requestEncryptionCredentials = lib.mkDefault [ ];

    # ZFS refuses to import a pool last used by another hostId. A hash
    # of the hostname is stable across reinstalls and needs no record;
    # the install script pins it in hardware-configuration.nix so that
    # a rename keeps it.
    networking.hostId = lib.mkDefault (
      builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName)
    );

    # In the systemd initrd, nixpkgs' root pool import is not ordered
    # after cryptsetup: it polls for the pool for about a minute and
    # then fails the boot, so a slow passphrase or FIDO2 PIN at the
    # prompt ends in emergency mode. The pool sits on the LUKS volume.
    boot.initrd.systemd.services = lib.mkIf config.boot.initrd.systemd.enable (
      lib.genAttrs (map (pool: "zfs-import-${pool}") rootPools) (_: {
        after = [ "cryptsetup.target" ];
        wants = [ "cryptsetup.target" ];
      })
    );

    systemd.services = lib.listToAttrs (map loadKeyService cfg.unlock);

    services.zfs.autoScrub = {
      enable = true;
      interval = cfg.scrubInterval;
    };

  };
}
