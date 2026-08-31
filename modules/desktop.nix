{
  config,
  lib,
  pkgs,
  ...
}:

# A complete desktop for every user: niri + Noctalia, with a working
# default config at /etc/niri/config.kdl (niri falls back to it when a
# user has no ~/.config/niri/config.kdl — see that file's header).
#
# niri is AVAILABLE, not REQUIRED: the greeter offers a session menu (F2)
# with niri and a plain "Shell" session, and remembers each user's choice.
let
  # A console session for the greeter. greetd runs Exec through the user's
  # login shell, so this lands in whatever shell the account has.
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

  # niri's module registers niri.desktop here; add the shell session too.
  sessionsDir = "${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
in
{
  options.core.desktop.enable = lib.mkEnableOption "graphical desktop (niri + greetd + Wayland plumbing + audio)";

  config = lib.mkIf config.core.desktop.enable {
    programs.niri.enable = true;
    hardware.graphics.enable = true;

    services.displayManager.sessionPackages = [ shellSession ];

    # The system-wide baseline desktop config (see header comment).
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

    # XDG portals come with programs.niri.enable: it turns on xdg.portal,
    # adds the gnome + gtk portals, and installs niri-portals.conf, which
    # picks the backend per interface. Nothing to add here.

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
    # noctalia (from the overlay in flake.nix) and the tools the default
    # config and noctalia shell out to: terminal, screenshots, night
    # light, media keys.
    environment.systemPackages = with pkgs; [
      noctalia
      alacritty
      grim
      slurp
      satty
      wlsunset
      playerctl
      xdg-utils
    ];
  };
}
