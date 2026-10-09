{
  config,
  lib,
  pkgs,
  ...
}:

# NymVPN daemon (nym-vpnd) and CLI client (nym-vpnc), packaged from the
# official release binaries (nixpkgs carries only the mixnet tools).
# One account per machine, stored in the daemon; the tunnel carries all
# users' traffic. The daemon keeps a requested connection alive but
# never initiates one: a wheel user runs `nym-vpnc connect`. Setup and
# daily commands: docs/vpn.md.

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
in
{
  options.core.nymvpn.enable = lib.mkEnableOption "NymVPN daemon (nym-vpnd) and CLI client";

  config = lib.mkIf cfg.enable {
    ## ----- packages ------------------------------------------------------------
    environment.systemPackages = [
      nym-vpn-core
      nym-vpnd-polkit-policy
    ];

    ## ----- polkit --------------------------------------------------------------
    # Wheel users get daemon access without a prompt; the auth_self
    # default requires a polkit agent.
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
  };
}
