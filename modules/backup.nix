{
  config,
  lib,
  pkgs,
  ...
}:

# ZFS-native backups between machines. A sender pushes raw (`zfs send
# -w`) streams of its encrypted datasets to a receiver; the receiver
# stores them as encrypted datasets whose key it never has. It can
# scrub, snapshot, prune and resilver what it holds, and read none of
# it. docs/backup.md has the design and the procedures.
#
# This module is the receiving side (core.backup.receive) and the
# `core-backup` command. Which senders a receiver accepts is state on
# the receiver (/var/lib/backup/recv), managed with `core-backup
# invite/accept/revoke`, not configuration.
let
  cfg = config.core.backup;

  # Receives one key over magic-wormhole, speaking `wormhole ssh
  # invite`'s protocol (see the script).
  wormholeReceive = pkgs.writers.writePython3Bin "core-backup-wormhole-receive" {
    libraries = [ pkgs.python3Packages.magic-wormhole ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/core-backup-wormhole-receive.py);

  coreBackup = pkgs.writeShellApplication {
    name = "core-backup";
    runtimeInputs = [
      config.boot.zfs.package
      wormholeReceive
      pkgs.magic-wormhole
      pkgs.openssh
      pkgs.shadow
      pkgs.getent
      pkgs.procps
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      CORE_BACKUP_DATASET=${lib.escapeShellArg cfg.receive.dataset}
    ''
    + builtins.readFile ../scripts/core-backup.sh;
  };
in
{
  options.core.backup = {
    package = lib.mkOption {
      type = lib.types.package;
      default = coreBackup;
      readOnly = true;
      internal = true;
      description = "The core-backup command.";
    };

    receive = {
      enable = lib.mkEnableOption "receiving raw ZFS replication from other machines";

      dataset = lib.mkOption {
        type = lib.types.str;
        default = "tank/recv";
        description = ''
          Parent of the received datasets; each accepted sender gets
          <dataset>/<name>. The pool must exist and be imported
          (core.zfs.pools).
        '';
      };

      retention = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {
          hourly = 0;
          daily = 60;
          monthly = 24;
          yearly = 3;
        };
        description = ''
          How many received snapshots of each sanoid period to keep.
          sanoid prunes by this policy, independent of the sender; it
          takes no snapshots of its own here, the snapshots are the
          senders'.
        '';
      };
    };
  };

  config = lib.mkIf cfg.receive.enable {
    assertions = [
      {
        assertion = config.core.zfs.enable;
        message = "core.backup.receive needs core.zfs.enable = true.";
      }
      {
        assertion = config.services.openssh.enable;
        message = "core.backup.receive needs services.openssh.enable = true; senders log in over SSH.";
      }
    ];

    # Each accepted sender's key, prefixed with `restrict`, written by
    # core-backup. Root-owned, so StrictModes is satisfied.
    services.openssh.authorizedKeysFiles = [ "/var/lib/backup/authorized_keys/%u" ];

    environment.systemPackages = [
      coreBackup
      # What syncoid runs on this end besides zfs.
      pkgs.mbuffer
      pkgs.lzop
      pkgs.zstd
      pkgs.pv
    ];

    # The receive accounts are created by `core-backup accept`. With
    # users.mutableUsers = false an activation rewrites /etc/passwd
    # without them; this puts them back, with the uids they had.
    system.activationScripts.backup-receive-users = lib.stringAfter [ "users" "groups" ] ''
      ${coreBackup}/bin/core-backup users || echo "core-backup: could not recreate receive accounts" >&2
    '';

    # At every boot: the parent dataset, and for each accepted sender
    # its key file, dataset, delegation (reset to exactly the list in
    # core-backup) and quota.
    systemd.services.backup-receive-setup = {
      description = "Set up the datasets and delegation for accepted backup senders";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-import.target" ];
      requires = [ "zfs-import.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${coreBackup}/bin/core-backup setup";
      };
    };

    # Prune what senders sent, by this machine's policy. sanoid's own
    # delegation (snapshot, destroy) is applied by the NixOS module for
    # the run and removed after.
    services.sanoid = {
      enable = true;
      templates.received = {
        autosnap = false;
        autoprune = true;
      }
      // cfg.receive.retention;
      datasets.${cfg.receive.dataset} = {
        useTemplate = [ "received" ];
        recursive = true;
        processChildrenOnly = true;
      };
    };
  };
}
