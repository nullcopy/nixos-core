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
# it. docs/backup.md has the design, the pool layout and the
# procedures.
#
# This module is the receiving side (core.backup.receive). Machines
# are identified by ../peers.nix, the registry of SSH host public
# keys. Every machine gets the registry as known hosts; a receiver
# additionally gets one locked-down account per sender it accepts.
let
  cfg = config.core.backup;

  peerModule =
    { name, ... }:
    {
      options = {
        hostKey = lib.mkOption {
          type = lib.types.str;
          description = ''
            The machine's SSH host public key (one line of
            /etc/ssh/ssh_host_ed25519_key.pub). Receivers accept it as
            the login key of recv-<name>; senders verify it as the host
            key of <name>.
          '';
        };
        address = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Where SSH reaches the machine. The tailnet resolves the name.";
        };
      };
    };

  recvUser = peer: "recv-${peer}";
  recvDataset = peer: "${cfg.receive.dataset}/${peer}";

  # What a sender may do under its own dataset. `receive:append` (no
  # `receive -F`), no `rollback` and no `destroy`: a sender adds
  # snapshots and can neither roll back nor remove what it sent
  # before, so a compromised sender cannot take its history here with
  # it. The encryption properties are what a raw stream carries and
  # sets on the datasets it creates.
  permissions = lib.concatStringsSep "," [
    "receive:append"
    "create"
    "mount"
    "hold"
    "release"
    "userprop"
    "canmount"
    "mountpoint"
    "compression"
    "encryption"
    "keyformat"
    "keylocation"
    "pbkdf2iters"
  ];
in
{
  options.core.backup = {
    peers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule peerModule);
      default = import ../peers.nix;
      description = ''
        The machines that take part in backups, by name. The default
        is nixos-core's registry, peers.nix; a machine repo can add
        entries.
      '';
    };

    receive = {
      enable = lib.mkEnableOption "receiving raw ZFS replication from backup peers";

      dataset = lib.mkOption {
        type = lib.types.str;
        default = "tank/recv";
        description = ''
          Parent of the received datasets; each accepted peer gets
          <dataset>/<peer>. The pool must exist and be imported
          (core.zfs.pools); the datasets are created at boot.
        '';
      };

      from = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "hawkeye" ];
        description = "Peers (names in core.backup.peers) allowed to send to this machine.";
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
          sanoid prunes by this policy as root, independent of the
          sender; it takes no snapshots of its own here, the snapshots
          are the senders'.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      # Every machine knows every peer's host key, so a sender never
      # sees a trust-on-first-use prompt.
      programs.ssh.knownHosts = lib.mapAttrs' (
        name: peer:
        lib.nameValuePair "backup-peer-${name}" {
          hostNames = lib.unique [
            name
            peer.address
          ];
          publicKey = peer.hostKey;
        }
      ) cfg.peers;
    }

    (lib.mkIf cfg.receive.enable {
      assertions = [
        {
          assertion = config.core.zfs.enable;
          message = "core.backup.receive needs core.zfs.enable = true.";
        }
        {
          assertion = config.services.openssh.enable;
          message = "core.backup.receive needs services.openssh.enable = true; senders log in over SSH.";
        }
        {
          assertion = lib.all (p: lib.hasAttr p cfg.peers) cfg.receive.from;
          message = "core.backup.receive.from names a peer that is not in core.backup.peers: ${
            lib.concatStringsSep ", " (lib.filter (p: !(lib.hasAttr p cfg.peers)) cfg.receive.from)
          }.";
        }
      ];

      # One account per sender. `restrict` leaves it with command
      # execution only: no pty, no forwarding. bash because syncoid
      # needs a POSIX shell on the remote end.
      users.users = lib.listToAttrs (
        map (
          peer:
          lib.nameValuePair (recvUser peer) {
            isSystemUser = true;
            group = recvUser peer;
            home = "/var/empty";
            shell = pkgs.bash;
            openssh.authorizedKeys.keys = [ "restrict ${cfg.peers.${peer}.hostKey}" ];
          }
        ) cfg.receive.from
      );
      users.groups = lib.listToAttrs (map (peer: lib.nameValuePair (recvUser peer) { }) cfg.receive.from);

      # What syncoid runs on the remote end besides zfs.
      environment.systemPackages = with pkgs; [
        mbuffer
        lzop
        zstd
        pv
      ];

      # The datasets and the delegation are pool state, not config.
      # This makes them follow the config: created when missing,
      # permissions (re)applied at every boot. `zfs allow` adds, so a
      # permission removed from the list above has to be taken away by
      # hand once: zfs unallow -u recv-<peer> <permission> <dataset>.
      systemd.services.backup-receive-setup = {
        description = "Create the datasets backup peers send to and delegate zfs receive to them";
        wantedBy = [ "multi-user.target" ];
        after = [ "zfs-import.target" ];
        requires = [ "zfs-import.target" ];
        path = [ config.boot.zfs.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          parent=${lib.escapeShellArg cfg.receive.dataset}
          zfs list -H -o name "$parent" >/dev/null 2>&1 \
            || zfs create -p -o mountpoint=none -o canmount=off "$parent"
          ${lib.concatMapStringsSep "\n" (peer: ''
            ds=${lib.escapeShellArg (recvDataset peer)}
            zfs list -H -o name "$ds" >/dev/null 2>&1 \
              || zfs create -o mountpoint=none -o canmount=off "$ds"
            zfs allow -u ${lib.escapeShellArg (recvUser peer)} ${permissions} "$ds"
          '') cfg.receive.from}
        '';
      };

      # Prune what senders sent, by this machine's policy. sanoid's
      # own delegation (snapshot, destroy) is applied by the NixOS
      # module for the run and removed after.
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
    })
  ];
}
