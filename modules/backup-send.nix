{
  config,
  lib,
  pkgs,
  ...
}:

# The sending side of the ZFS-native backups (core.backup.send): a
# wrapper around services.syncoid that pushes raw streams of this
# machine's encrypted datasets to receivers from the peer registry.
# See docs/backup.md; the receiving side is in ./backup.nix.
let
  cfg = config.core.backup;
  send = cfg.send;
  me = config.networking.hostName;

  # tank/local -> local, rpool/home -> home: the dataset under the
  # receiver's tank/recv/<me>/.
  stripPool = ds: lib.concatStringsSep "/" (lib.drop 1 (lib.splitString "/" ds));

  # The unit name the syncoid module derives from a command name.
  unitName = name: "syncoid-${lib.replaceStrings [ "/" ] [ "-" ] name}";

  # One syncoid command per (dataset, peer).
  jobs = lib.concatLists (
    lib.mapAttrsToList (
      ds: opts:
      map (peer: {
        name = "${ds}/${peer}";
        source = ds;
        inherit peer;
        target = "recv-${me}@${cfg.peers.${peer}.address}:${send.remoteDataset}/${me}/${stripPool ds}";
      }) opts.to
    ) send.datasets
  );

  # The host key is root-only; LoadCredential hands a copy to the
  # sandboxed syncoid user for the run.
  credential = "sshkey";
  credentialPath = name: "/run/credentials/${unitName name}.service/${credential}";

  refuseUnencrypted =
    ds:
    pkgs.writeShellScript "refuse-unencrypted" ''
      enc=$(${config.boot.zfs.package}/bin/zfs get -H -o value encryption ${lib.escapeShellArg ds})
      if [ "$enc" = off ]; then
        echo "core.backup.send: ${ds} is not encrypted; refusing to replicate it in the clear" >&2
        exit 1
      fi
    '';
in
{
  options.core.backup.send = {
    datasets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.to = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Receivers (names in core.backup.peers) this dataset is sent to.";
          };
        }
      );
      default = { };
      example = {
        "tank/local".to = [ "obelisk" ];
      };
      description = ''
        Encrypted datasets to replicate, each with the peers that
        receive it. Sent raw and recursively; a dataset that is not
        encrypted fails the run rather than leave the receiver with
        plaintext. Enabling any dataset turns on sanoid snapshots of
        it by `core.backup.send.snapshots`.
      '';
    };

    remoteDataset = lib.mkOption {
      type = lib.types.str;
      default = "tank/recv";
      description = "The receivers' core.backup.receive.dataset; this machine's data lands under <it>/<hostname>.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd calendar expression for the sends.";
    };

    snapshots = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = {
        hourly = 24;
        daily = 30;
        monthly = 12;
        yearly = 1;
      };
      description = ''
        sanoid policy for the sent datasets on this machine: how many
        snapshots of each period to take and keep here. Receivers keep
        their own, longer history (core.backup.receive.retention).
      '';
    };
  };

  config = lib.mkIf (jobs != [ ]) {
    assertions = [
      {
        assertion = config.core.zfs.enable;
        message = "core.backup.send needs core.zfs.enable = true.";
      }
      {
        assertion = lib.all (j: lib.hasAttr j.peer cfg.peers) jobs;
        message = "core.backup.send names a peer that is not in core.backup.peers: ${
          lib.concatStringsSep ", " (
            lib.unique (map (j: j.peer) (lib.filter (j: !(lib.hasAttr j.peer cfg.peers)) jobs))
          )
        }.";
      }
    ];

    core.alerts.onFailure = [ "sanoid" ] ++ map (j: unitName j.name) jobs;

    # Snapshots are taken here; syncoid only ships them (--no-sync-snap).
    services.sanoid = {
      enable = true;
      templates.sent = {
        autosnap = true;
        autoprune = true;
      }
      // send.snapshots;
      datasets = lib.mapAttrs (ds: _: {
        useTemplate = [ "sent" ];
        recursive = true;
      }) send.datasets;
    };

    services.syncoid = {
      enable = true;
      interval = send.interval;
      # syncoid runs on the source as its own user; these are the only
      # zfs rights it gets here. No destroy: nothing is pruned by the
      # send, sanoid does that.
      localSourceAllow = [
        "bookmark"
        "hold"
        "send"
        "snapshot"
      ];
      commonArgs = [
        "--no-sync-snap" # sanoid's snapshots, not syncoid's
        "--no-rollback" # never `receive -F`; the receiver account cannot anyway
        # (--no-privilege-elevation comes from the NixOS module: delegated rights, no sudo)
        "--recursive"
      ];
      commands = lib.listToAttrs (
        map (
          j:
          lib.nameValuePair j.name {
            inherit (j) source target;
            sendOptions = "w"; # raw: the receiver gets ciphertext and the wrapped key
            recvOptions = "u"; # the receiver cannot mount it anyway
            sshKey = credentialPath j.name;
            service.serviceConfig = {
              LoadCredential = [ "${credential}:/etc/ssh/ssh_host_ed25519_key" ];
              # Refuse to send plaintext. Checked at run time, since
              # encryption is a property of the pool, not the config.
              # "+" runs it outside the sandbox, like the module's own
              # `zfs allow` steps; /dev/zfs is not in the sandbox for
              # ExecStartPre.
              ExecStartPre = [ "+${refuseUnencrypted j.source}" ];
            };
          }
        ) jobs
      );
    };
  };
}
