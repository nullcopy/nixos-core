{
  config,
  lib,
  pkgs,
  ...
}:

# NymVPN daemon (nym-vpnd) and CLI client (nym-vpnc), packaged from the
# official release binaries (nixpkgs carries only the mixnet tools).
# One account per machine, stored in the daemon; the tunnel carries all
# users' traffic. Setup and daily commands: docs/new-machine.md, step 6.

let
  # To update: bump version, then hash (from the release, or from the
  # first failed rebuild).
  version = "2026.10.0";

  nym-vpn-core = pkgs.stdenv.mkDerivation {
    pname = "nym-vpn-core";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/nymtech/nym-vpn-client/releases/download/nym-vpn-core-v${version}/nym-vpn-core-v${version}_linux_x86_64.tar.gz";
      hash = "sha256-k5q4MtwiS2J8Q7bCpWIHO6XbzVMFeavjvhOtH9ITbJs=";
    };

    sourceRoot = "nym-vpn-core-v${version}_linux_x86_64";

    # autoPatchelfHook points the generic-Linux binaries at nix store
    # libraries. The buildInputs list comes from readelf -d.
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = with pkgs; [
      dbus
      libmnl
      libnftnl
      stdenv.cc.cc.lib
    ];

    installPhase = ''
      runHook preInstall
      install -Dm755 nym-vpnd nym-vpnc -t $out/bin
      runHook postInstall
    '';

    meta = {
      description = "NymVPN daemon and CLI client (official prebuilt binaries)";
      homepage = "https://nym.com";
      license = lib.licenses.gpl3Only;
      platforms = [ "x86_64-linux" ];
    };
  };

  # nym-vpnd authorizes socket clients via a polkit action baked into
  # the binary. This ships the upstream .policy file that declares it
  # (systemPackages links share/polkit-1/actions into polkit's path).
  nym-vpnd-polkit-policy = pkgs.writeTextFile {
    name = "nym-vpnd-polkit-policy";
    destination = "/share/polkit-1/actions/com.nymvpn.vpnd.unix-access.policy";
    text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <policyconfig>
        <action id="com.nymvpn.vpnd.unix-access">
          <description>Connect via unix socket</description>
          <message>Authentication is required to connect to the daemon</message>

          <defaults>
            <allow_any>auth_admin</allow_any>
            <allow_inactive>auth_admin</allow_inactive>
            <allow_active>auth_self</allow_active>
          </defaults>
        </action>
      </policyconfig>
    '';
  };

  cfg = config.core.nymvpn;
  nym-vpnc = "${nym-vpn-core}/bin/nym-vpnc";
in
{
  options.core.nymvpn = {
    enable = lib.mkEnableOption "NymVPN daemon (nym-vpnd) and CLI client";

    autoconnect = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Connect the tunnel at boot. Until the admin stores the account
        (`nym-vpnc account set`), the service logs a hint and exits.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    ## ----- packages ------------------------------------------------------------
    environment.systemPackages = [
      nym-vpn-core
      nym-vpnd-polkit-policy
    ];

    ## ----- polkit --------------------------------------------------------------
    # Wheel users and root (the autoconnect service) get daemon access
    # without a prompt; the auth_self default requires a polkit agent.
    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "com.nymvpn.vpnd.unix-access" &&
              (subject.user == "root" || subject.isInGroup("wheel"))) {
            return polkit.Result.YES;
          }
        });
      '';
    };

    ## ----- daemon --------------------------------------------------------------
    # The unit matches the official .deb, plus an explicit PATH: the
    # daemon runs these network tools at tunnel setup and fails with
    # Error(TunDevice) without them.
    systemd.services.nym-vpnd = {
      description = "NymVPN daemon";
      wantedBy = [ "multi-user.target" ];
      before = [ "network-online.target" ];
      after = [
        "NetworkManager.service"
        "systemd-resolved.service"
      ];
      path = with pkgs; [
        iproute2
        iptables
        nftables
        coreutils
      ];
      startLimitBurst = 6;
      startLimitIntervalSec = 24;
      serviceConfig = {
        ExecStart = "${nym-vpn-core}/bin/nym-vpnd -v run-as-service";
        Restart = "always";
        RestartSec = 2;
      };
    };

    ## ----- autoconnect -----------------------------------------------------------
    # nym-vpnd keeps a requested connection alive but never initiates
    # one; this service requests the first connection at boot. Stop the
    # unit to disconnect.
    systemd.services.nym-vpn-autoconnect = lib.mkIf cfg.autoconnect {
      description = "Connect the machine-wide NymVPN tunnel";
      wantedBy = [ "multi-user.target" ];
      requires = [ "nym-vpnd.service" ];
      after = [ "nym-vpnd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Wait for the nym-vpnd socket.
        for _ in $(seq 1 30); do
          ${nym-vpnc} status >/dev/null 2>&1 && break
          sleep 1
        done
        if ! ${nym-vpnc} account get >/dev/null 2>&1; then
          echo "No usable NymVPN account; skipping connect. A wheel user runs:" >&2
          echo "  nym-vpnc account set '<mnemonic>' && sudo systemctl restart nym-vpn-autoconnect" >&2
          exit 0
        fi
        if ! timeout 90 ${nym-vpnc} connect --wait; then
          echo "NymVPN connect failed; the daemon firewall stays up." >&2
          echo "Investigate: nym-vpnc status; journalctl -u nym-vpnd" >&2
          echo "Deliberate bypass: sudo systemctl stop nym-vpn-autoconnect nym-vpnd" >&2
          exit 1
        fi
      '';
      preStop = ''
        ${nym-vpnc} disconnect || true
      '';
    };
  };
}
