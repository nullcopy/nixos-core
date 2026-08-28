{
  config,
  lib,
  pkgs,
  ...
}:

# NymVPN daemon (nym-vpnd) + CLI client (nym-vpnc).
#
# Not in nixpkgs — the `nym` package there is only the mixnet infrastructure
# binaries — so this packages the official prebuilt release binaries from
# https://github.com/nymtech/nym-vpn-client/releases instead.
#
# The account and the tunnel are MACHINE-wide: one account per machine,
# stored daemon-side, and the tunnel carries every user's traffic. There
# is no per-user account or per-user config anywhere in dotfiles, and
# users other than the admin never touch nym at all.
#
# First-time setup, once per machine, by a wheel user (needs an account
# from https://nym.com):
#   nym-vpnc account store    # paste the account mnemonic when prompted
#   sudo systemctl restart nym-vpn-autoconnect
#
# From then on nym-vpn-autoconnect brings the tunnel up at every boot
# (core.nymvpn.autoconnect, default true). It is the default route for
# all traffic; with core.tailscale.enable, tailnet destinations still go
# over tailscale (no exit node), and everything else through NymVPN.
#
# Admin control:
#   nym-vpnc status
#   sudo systemctl stop nym-vpn-autoconnect     # disconnect until next boot
#   sudo systemctl start nym-vpn-autoconnect    # reconnect
#
# To update: bump `version`, then replace `hash` with the value from the
# release's hashes (or let the rebuild fail once and copy the hash nix prints).

let
  version = "2026.10.0";

  nym-vpn-core = pkgs.stdenv.mkDerivation {
    pname = "nym-vpn-core";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/nymtech/nym-vpn-client/releases/download/nym-vpn-core-v${version}/nym-vpn-core-v${version}_linux_x86_64.tar.gz";
      hash = "sha256-k5q4MtwiS2J8Q7bCpWIHO6XbzVMFeavjvhOtH9ITbJs=";
    };

    sourceRoot = "nym-vpn-core-v${version}_linux_x86_64";

    # The prebuilt binaries target generic Linux; autoPatchelfHook rewrites
    # their ELF interpreter/rpath to nix store paths. nym-vpnd links against
    # libmnl/libnftnl (firewall rules), libdbus (DNS via NetworkManager /
    # systemd-resolved), and libgcc_s (stdenv.cc.cc.lib) — checked with
    # readelf -d.
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

  # nym-vpnd authorizes clients on its unix socket through polkit, using an
  # action id baked into the binary. Polkit only recognizes actions declared
  # in a .policy file, so ship upstream's (the .deb relies on the distro's
  # /usr/share/polkit-1/actions; on NixOS, packages in systemPackages get
  # share/polkit-1/actions linked to where polkit looks). Verbatim from
  # nym-vpn-core/crates/nym-ipc/.pkg/com.nymvpn.vpnd.unix-access.policy.
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
        Connect the machine-wide NymVPN tunnel at boot, once the admin has
        stored the account with `nym-vpnc account store`. Until then the
        service logs a hint and does nothing.
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
    # Grant wheel users (and root, for the autoconnect service) daemon
    # access without an auth prompt: the upstream default of auth_self
    # needs a polkit authentication agent, which this niri setup doesn't
    # run. Non-wheel users are simply unable to drive the daemon — they
    # don't need to, the tunnel is already up for them.
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
    # Mirrors the unit shipped in the official .deb, plus an explicit PATH:
    # the daemon shells out to these network tools at tunnel setup, and on
    # NixOS they aren't in a system service's default PATH (without them it
    # fails with Error(TunDevice)). Running the daemon is harmless on its own;
    # like tailscaled, it creates no tunnel until a client asks it to connect.
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
    # Machine-wide tunnel at boot. Runs as root (polkit rule above), so it
    # works regardless of which user logs in, or none. Stopping the unit
    # disconnects.
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
        # nym-vpnd's socket comes up a moment after the unit starts.
        for _ in $(seq 1 30); do
          ${nym-vpnc} status >/dev/null 2>&1 && break
          sleep 1
        done
        if ! ${nym-vpnc} connect; then
          echo "nym-vpnc connect failed. Not set up yet? A wheel user runs:" >&2
          echo "  nym-vpnc account store && sudo systemctl restart nym-vpn-autoconnect" >&2
          exit 0
        fi
      '';
      preStop = ''
        ${nym-vpnc} disconnect || true
      '';
    };
  };
}
