{ pkgs, lib, inputs, ... }:
let
  screensaver = pkgs.rustPlatform.buildRustPackage {
    pname = "hyprsaver";
    version = "0.4.8";
    src = inputs.hyprsaver-src;
    cargoLock.lockFile = inputs.hyprsaver-src + "/Cargo.lock";
    nativeBuildInputs = [ pkgs.pkg-config pkgs.cmake pkgs.patchelf ];
    buildInputs = [ pkgs.wayland pkgs.libGL pkgs.libxkbcommon pkgs.mesa ];
    # Wayland and EGL are opened with dlopen, so ELF NEEDED is insufficient.
    postFixup = ''
      patchelf --add-rpath ${lib.makeLibraryPath [ pkgs.wayland pkgs.libGL pkgs.libxkbcommon pkgs.mesa ]} $out/bin/hyprsaver
    '';
  };
  saverConfig = pkgs.writeText "hyprsaver.toml" ''
    [general]
    fps = 30
    shader = "cycle"
    palette = "cycle"
    shader_cycle_interval = 180
    palette_cycle_interval = 60
    cycle_order = "random"
    synced = true
    shader_playlist = "cinematic"
    palette_playlist = "cinematic"

    [behavior]
    fade_in_ms = 1200
    fade_out_ms = 400
    dismiss_on = ["key", "mouse_move", "mouse_click", "touch"]
    exclusive_keyboard = true

    [playlists.cinematic]
    shaders = ["aurora", "starfield", "julia", "caustics", "marble", "planet", "kaleidoscope", "fractaltrap"]
    palettes = ["aurora", "vaporwave", "ocean", "frost"]
  '';
  sessionPython = pkgs.python3.withPackages (p: [ p.dbus-python p.pygobject3 ]);
  sessionCheck = "${sessionPython}/bin/python3 ${./screensaver-session.py}";
  # This hypridle version discovers its default config even with --config.
  # Give only this service a private XDG tree; do not alter the user's KDE paths.
  idleConfig = pkgs.writeTextDir "hypr/hypridle.conf" ''
    general {
      inhibit_sleep = 0
      # KDE owns org.freedesktop.ScreenSaver. The gate below reads KDE's
      # inhibitors instead of trying to replace that D-Bus service.
      ignore_dbus_inhibit = true
      ignore_wayland_inhibit = false
    }
    listener {
      timeout = 600
      on-timeout = ${pkgs.systemd}/bin/systemctl --user start cinematic-screensaver.service
      on-resume = ${pkgs.systemd}/bin/systemctl --user stop cinematic-screensaver.service
    }
    # Release rendering and the keyboard grab before PowerDevil's 30-minute
    # DPMS timeout. Keep Plasma's existing four-hour authentication policy.
    listener {
      timeout = 1790
      on-timeout = ${pkgs.systemd}/bin/systemctl --user stop cinematic-screensaver.service
    }
  '';
in {
  systemd.user.services.cinematic-screensaver = {
    description = "Cinematic shader screensaver across every connected monitor";
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecCondition = "${sessionCheck} --allowed";
      ExecStart = "${screensaver}/bin/hyprsaver --config ${saverConfig}";
      TimeoutStopSec = 5;
    };
  };
  systemd.user.services.screensaver-session = {
    description = "Stop visual screensaver when Plasma locks or inhibits display idle";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${sessionCheck} ${pkgs.systemd}/bin/systemctl";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
  systemd.user.services.screensaver-idle = {
    description = "Start cinematic screensaver after ten idle minutes";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Environment = "XDG_CONFIG_HOME=${idleConfig}";
      ExecStart = "${pkgs.hypridle}/bin/hypridle";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
