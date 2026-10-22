{ pkgs, ... }:
let
  # KDE has no per-reminder duration setting: its popups otherwise disappear
  # when a short event ends or remain indefinitely. Patch only the daemon we
  # launch, avoiding a rebuild of every application using its calendar library.
  calendarReminders = pkgs.kdePackages.akonadi-calendar.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./patches/calendar-reminder-hour.patch ];
  });
  python = pkgs.python3.withPackages (p: [
    p.google-auth p.requests p.icalendar p.dbus-python
  ]);
in {
  environment.systemPackages = with pkgs.kdePackages; [
    korganizer akonadi-calendar akonadi-calendar-tools kdepim-runtime
  ];

  # KDE's Google resource requires interactive OAuth and cannot use the service
  # account already shared with our calendar. Feed its read-only iCal resource
  # instead. The key and account settings stay outside Git and the Nix store.
  systemd.user.services.calendar-sync = {
    description = "Google Calendar events and invitation notifications";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionPathExists = "%h/.config/calendar-sync/config.json";
    serviceConfig = {
      ExecStart = "${python}/bin/python ${./calendar-sync.py}";
      Restart = "on-failure";
      RestartSec = 30;
      UMask = "0077";
    };
    path = [ pkgs.kdePackages.akonadi-calendar-tools pkgs.systemd ];
  };

  # Use KDE's existing autostart unit so only one reminder daemon owns alarms.
  systemd.user.services."app-org.kde.kalendarac@autostart" = {
    description = "KOrganizer popup reminders";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig.ExecStart = "${calendarReminders}/bin/kalendarac";
    serviceConfig.Restart = "on-failure";
    serviceConfig.RestartSec = 10;
  };

  home-manager.users.niteris.programs.plasma.configFile = {
    kalendaracrc.General.Autostart = true;
    # The notification widget is on our primary panel; put its popups in the
    # upper-right corner. Also applies to other app popups.
    plasmanotifyrc.Notifications.PopupPosition = "TopRight";
  };
}
