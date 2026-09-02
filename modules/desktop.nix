{
  config,
  lib,
  pkgs,
  ...
}:

# A complete desktop for every user: niri + Noctalia via
# /etc/niri/config.kdl; a user's own ~/.config/niri/config.kdl replaces
# it. The greeter session menu (F3) offers niri and a plain Shell
# session.
let
  # Console session: greetd runs Exec through the user's login shell.
  shellSession = pkgs.writeTextFile {
    name = "shell-session";
    destination = "/share/wayland-sessions/shell.desktop";
    text = ''
      [Desktop Entry]
      Name=Shell
      Comment=Plain login shell on this console, no desktop
      Exec=/bin/sh -lc 'exec "$SHELL" -l'
      Type=Application
    '';
    derivationArgs.passthru.providedSessions = [ "shell" ];
  };

  # The niri module registers niri.desktop here; add the shell session.
  sessionsDir = "${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
in
{
  options.core.desktop.enable = lib.mkEnableOption "graphical desktop (niri + greetd + Wayland plumbing + audio)";

  config = lib.mkIf config.core.desktop.enable {
    programs.niri.enable = true;
    hardware.graphics.enable = true;

    services.displayManager.sessionPackages = [ shellSession ];

    # The system-wide default niri configuration.
    environment.etc."niri/config.kdl".source = ./niri-default-config.kdl;

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = lib.concatStringsSep " " [
          (lib.getExe pkgs.tuigreet)
          "--sessions ${sessionsDir}"
          "--remember"
          "--remember-user-session"
          "--time"
        ];
        user = "greeter";
      };
    };

    # Login through greetd unlocks the GNOME keyring, where Brave and
    # other apps keep their secrets.
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.greetd.enableGnomeKeyring = true;

    # programs.niri.enable configures the XDG portals
    # (niri-portals.conf selects the backends). The document portal
    # mounts a FUSE filesystem through the setuid fusermount3 wrapper,
    # which libfuse spawns via PATH lookup; without the wrapper dir on
    # the unit's PATH the portal fails and degrades the user session.
    systemd.user.services.xdg-document-portal.path = [
      "/run/wrappers"
      "/run/current-system/sw"
    ];

    ## ----- audio -------------------------------------------------------------
    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    ## ----- bluetooth ---------------------------------------------------------
    hardware.bluetooth = {
      enable = lib.mkDefault true;
      powerOnBoot = lib.mkDefault false;
    };

    ## ----- power management ----------------------------------------------------
    services.power-profiles-daemon.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;

    ## ----- desktop shell + companions ------------------------------------------
    # noctalia (overlay in flake.nix) plus the programs the default
    # configuration starts.
    environment.systemPackages = with pkgs; [
      noctalia
      alacritty
      brave
      grim
      slurp
      satty
      wlsunset
      playerctl
      xdg-utils
    ];
  };
}
