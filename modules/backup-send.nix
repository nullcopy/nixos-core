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

  # tank/encrypted -> encrypted, rpool/encrypted -> encrypted: the dataset under the
  # receiver's tank/recv/<me>/.
  components = ds: lib.splitString "/" ds;
  stripPool = ds: lib.concatStringsSep "/" (lib.drop 1 (components ds));
  parentOf = ds: lib.concatStringsSep "/" (lib.init (components ds));

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
        target = "recv-${me}@${peer}:${send.remoteDataset}/${me}/${stripPool ds}";
      }) opts.to
    ) send.datasets
  );

  # The machine's backup identity: an SSH key made at first boot, whose
  # public half a receiver accepts with `core-backup invite`. It is
  # root-only on disk; LoadCredential hands a copy to the sandboxed syncoid user for
  # the run. The syncoid process parses what remote machines send it,
  # so it holds this append-only identity and not the host key.
  keyDir = "/var/lib/backup";
  keyFile = "${keyDir}/key";
  credential = "sshkey";
  credentialPath = name: "/run/credentials/${unitName name}.service/${credential}";

  # A friendlier error than the kernel's. The delegation below
  # (send:encrypted) is what actually enforces it.
  refuseUnencrypted =
    ds:
    pkgs.writeShellScript "refuse-unencrypted" ''
      enc=$(${config.boot.zfs.package}/bin/zfs get -H -o value encryption ${lib.escapeShellArg ds}) || enc=
      if [ -z "$enc" ] || [ "$enc" = off ]; then
        echo "core.backup.send: ${ds} is not encrypted (encryption=''${enc:-unknown}); refusing to replicate it in the clear" >&2
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
            description = "Receivers this dataset is sent to, by hostname or address (the tailnet resolves names). Each must have accepted this machine with `core-backup invite`.";
          };
        }
      );
      default = { };
      example = {
        "tank/encrypted".to = [ "obelisk" ];
      };
      description = ''
        Encrypted datasets to replicate, each with the peers that
        receive it. Sent raw and recursively; a dataset that is not
        encrypted fails the run rather than leave the receiver with
        plaintext. A nested dataset (tank/encrypted/foo) needs its parent
        sent to the same peers, since the receiver does not create
        intermediate datasets. Enabling any dataset turns on sanoid
        snapshots of it by `core.backup.send.snapshots`.
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
        their own, longer history (core.backup.receive.retention). An
        incremental send needs the receiver's newest snapshot to still
        exist here, so `daily` is also the longest outage of a receiver
        that sends recover from on their own (docs/backup.md).
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
        # The kernel only knows the send:encrypted delegation from 2.4;
        # on older zfs the unit's `zfs allow` fails at runtime.
        assertion =
          lib.versionAtLeast (lib.versions.majorMinor config.boot.zfs.package.version) "2.4";
        message = "core.backup.send needs the send:encrypted delegation, OpenZFS 2.4 or newer; zfs is ${config.boot.zfs.package.version}.";
      }
      {
        assertion = lib.all (ds: lib.length (components ds) >= 2) (lib.attrNames send.datasets);
        message = "core.backup.send.datasets: send a dataset (tank/encrypted), not a pool (tank).";
      }
      {
        assertion = lib.all (
          ds:
          lib.length (components ds) <= 2
          || (
            lib.hasAttr (parentOf ds) send.datasets
            && lib.all (p: lib.elem p send.datasets.${parentOf ds}.to) send.datasets.${ds}.to
          )
        ) (lib.attrNames send.datasets);
        message = "core.backup.send.datasets: a nested dataset needs its parent sent to the same peers; the receiver does not create intermediate datasets.";
      }
    ];

    # syncoid calls ssh from the unit's PATH (/run/booted-system/sw/bin);
    # openssh is not in NixOS defaultPackages and the sender need not run
    # sshd, so name it here.
    environment.systemPackages = [
      config.core.backup.package
      pkgs.openssh
    ];

    core.alerts.onFailure = [
      "sanoid"
      "backup-keygen"
    ]
    ++ map (j: unitName j.name) jobs;

    # The identity. Made once; `core-backup join` sends the public half
    # to a receiver's `core-backup invite`.
    systemd.services.backup-keygen = {
      description = "Create this machine's backup SSH key";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "!${keyFile}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        # The directory and the public half are world-readable so
        # `core-backup join` works without root; the key is not.
        install -d -m 755 ${keyDir}
        ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "backup@${me}" -f ${keyFile}
        chmod 600 ${keyFile}
        chmod 644 ${keyFile}.pub
        echo "backup key created; pair it with a receiver: core-backup join CODE" >&2
      '';
    };

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
      # zfs rights it gets here. send:encrypted: raw streams of
      # encrypted datasets only, enforced by the kernel. No destroy:
      # nothing is pruned by the send, sanoid does that.
      localSourceAllow = [
        "bookmark"
        "hold"
        "send:encrypted"
        "snapshot"
      ];
      commonArgs = [
        "--no-sync-snap" # sanoid's snapshots, not syncoid's
        "--no-rollback" # never `receive -F`; the receiver account cannot anyway
        # (--no-privilege-elevation comes from the NixOS module: delegated rights, no sudo)
        "--recursive"
        "--compress"
        "none" # ciphertext does not compress
        # The receiver's host key is trusted on first use and pinned
        # here. The tailnet already authenticates the address.
        "--sshoption=StrictHostKeyChecking=accept-new"
        "--sshoption=UserKnownHostsFile=/var/lib/syncoid/known_hosts"
      ];
      commands = lib.listToAttrs (
        map (
          j:
          lib.nameValuePair j.name {
            inherit (j) source target;
            sendOptions = "w"; # raw: the receiver gets ciphertext and the wrapped key
            recvOptions = "u"; # the receiver cannot mount it anyway
            sshKey = credentialPath j.name;
            service = {
              after = [ "backup-keygen.service" ];
              requires = [ "backup-keygen.service" ];
              serviceConfig = {
                LoadCredential = [ "${credential}:${keyFile}" ];
                # "+" runs it outside the sandbox, like the module's own
                # `zfs allow` steps; /dev/zfs is not in the sandbox for
                # ExecStartPre.
                ExecStartPre = [ "+${refuseUnencrypted j.source}" ];
              };
            };
          }
        ) jobs
      );
    };
  };
}
