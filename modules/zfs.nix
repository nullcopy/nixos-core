{
  config,
  lib,
  pkgs,
  ...
}:

# ZFS support for data pools on attached drives: kernel module and
# tools, pool import at boot, key loading, scrubs. The root stays on
# btrfs; nothing here touches the install layout. docs/zfs.md has how
# pools and keys are handled, and `core-zpool` creates a pool.
let
  cfg = config.core.zfs;

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
  };

  config = lib.mkIf cfg.enable {
    # nixpkgs' zfs is built against the default (LTS) kernel and the
    # build fails loudly if a machine picks a kernel ZFS does not
    # support yet, so a `boot.kernelPackages = linuxPackages_latest`
    # override may have to wait for ZFS.
    boot.supportedFilesystems.zfs = true;
    boot.zfs.extraPools = cfg.pools;
    boot.zfs.requestEncryptionCredentials = cfg.unlock;
    # The root is not on ZFS; never force an import.
    boot.zfs.forceImportRoot = lib.mkDefault false;

    # ZFS refuses to import a pool last used by another hostId. A hash
    # of the hostname is stable across reinstalls and needs no record.
    # A renamed machine imports its pools once with `zpool import -f`,
    # or pins the old value here.
    networking.hostId = lib.mkDefault (
      builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName)
    );

    services.zfs.autoScrub = {
      enable = true;
      interval = cfg.scrubInterval;
    };

    environment.systemPackages = [ zpoolWizard ];
  };
}
