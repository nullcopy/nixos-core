{
  config,
  lib,
  pkgs,
  ...
}:

# ZFS support: kernel module and tools, pool import at boot, scrubs.
# The hostId is derived from the hostname, so a reinstalled machine
# imports its old pools without -f and nothing per machine needs to be
# remembered. docs/backup.md has the pool layout the backup modules
# expect.
let
  cfg = config.core.zfs;
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
      example = [ "tank/local" ];
      description = ''
        Encrypted datasets whose keys are loaded at import. Their
        keylocation should be a file on the (LUKS-encrypted) root,
        under /etc/zfs/keys. Nothing else is unlocked: datasets
        received from backup peers carry a key this machine does not
        have, and the NixOS default of unlocking everything would stop
        at a prompt for it during boot.
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
    boot.zfs.requestEncryptionCredentials = cfg.unlock;

    # ZFS refuses to import a pool last used by another hostId. A hash
    # of the hostname is stable across reinstalls and needs no record.
    networking.hostId = lib.mkDefault (
      builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName)
    );

    services.zfs.autoScrub = {
      enable = true;
      interval = cfg.scrubInterval;
    };
  };
}
