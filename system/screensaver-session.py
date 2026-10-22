"""Gate the visual screensaver on Plasma's lock and display-inhibit state."""
import subprocess
import sys

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()


def allowed():
    locker = dbus.Interface(
        bus.get_object("org.freedesktop.ScreenSaver", "/ScreenSaver"),
        "org.freedesktop.ScreenSaver",
    )
    policy = dbus.Interface(
        bus.get_object(
            "org.kde.Solid.PowerManagement.PolicyAgent",
            "/org/kde/Solid/PowerManagement/PolicyAgent",
        ),
        "org.kde.Solid.PowerManagement.PolicyAgent",
    )
    # ChangeScreenSettings = 4: suspend-only inhibitors need not hide the saver.
    return not locker.GetActive(timeout=3) and not policy.HasInhibition(4, timeout=3)


def stop_if_blocked(*_args):
    try:
        if not allowed():
            subprocess.run(
                [sys.argv[1], "--user", "stop", "cinematic-screensaver.service"],
                check=True,
                timeout=10,
            )
    except (dbus.DBusException, subprocess.SubprocessError) as error:
        print(f"Screensaver session check: {error}", file=sys.stderr, flush=True)
    return True


if sys.argv[1:] == ["--allowed"]:
    try:
        sys.exit(0 if allowed() else 1)
    except dbus.DBusException as error:
        print(error, file=sys.stderr)
        sys.exit(1)  # Fail closed while Plasma is restarting.

bus.add_signal_receiver(
    stop_if_blocked,
    signal_name="ActiveChanged",
    dbus_interface="org.freedesktop.ScreenSaver",
)
bus.add_signal_receiver(
    stop_if_blocked,
    signal_name="InhibitionsChanged",
    dbus_interface="org.kde.Solid.PowerManagement.PolicyAgent",
)
stop_if_blocked()
GLib.MainLoop().run()
