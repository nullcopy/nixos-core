{
  config,
  lib,
  pkgs,
  ...
}:

# Everything a graphical workstation needs at the system level: the niri
# compositor, a login greeter, portals, audio, bluetooth, and power
# management. User-level desktop config (noctalia, keybindings, terminal)
# lives in each user's home-manager repo, gated by its own desktop option.
#
# niri is AVAILABLE, not REQUIRED: the greeter offers a session menu (F2)
# with niri and a plain "Shell" session that just runs the user's login
# shell on the console, and remembers each user's last choice. A user
# without a graphical setup (no dotfiles yet, or none wanted) picks Shell.
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

    ## ----- noctalia companions -------------------------------------------------
    # Tools noctalia (the Wayland shell users run via home-manager) shells
    # out to for screenshots, night light, and media keys.
    environment.systemPackages = with pkgs; [
      grim
      slurp
      satty
      wlsunset
      playerctl
      xdg-utils
    ];
  };
}
