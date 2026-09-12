"""Own the local resolver and load/unload its KWin script with the user session."""
import json
import os
from pathlib import Path
import signal
import sys

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib, GLibUnix

from resolver import Resolver


NAME = "org.nixos.LaunchOrigin"
PLUGIN = "nixos-launch-origin"


class Service(dbus.service.Object):
    def __init__(self, bus):
        self.name = dbus.service.BusName(NAME, bus=bus, do_not_queue=True)
        super().__init__(self.name, "/org/nixos/LaunchOrigin")
        self.resolver = Resolver(runtime=Path(os.environ["XDG_RUNTIME_DIR"]))

    @dbus.service.method(NAME, in_signature="ss", out_signature="s",
                         async_callbacks=("reply", "error"))
    def Resolve(self, pid, windows, reply, error):
        try:
            process_id, snapshot = int(pid), json.loads(windows)
        except (ValueError, TypeError, KeyError):
            reply("")
            return
        remaining = 6

        def attempt():
            nonlocal remaining
            remaining -= 1
            try:
                source = self.resolver.resolve(process_id, snapshot)
            except (ValueError, TypeError, KeyError):
                source = ""
                remaining = 0
            if source or remaining == 0:
                reply(source)
                return False
            return True

        # A fast application can map before kitty's next metadata publication.
        # Retry asynchronously for up to one heartbeat; never block KWin.
        if attempt():
            GLib.timeout_add(100, attempt)


def main():
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    service = Service(bus)
    loop = GLib.MainLoop()

    def scripting():
        return dbus.Interface(bus.get_object("org.kde.KWin", "/Scripting"),
                              "org.kde.kwin.Scripting")

    def load():
        try:
            interface = scripting()
            interface.unloadScript(PLUGIN)
            # KWin overloads loadScript with one and two arguments. dbus-python
            # otherwise selects the one-argument introspection signature.
            script_id = bus.call_blocking(
                "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting",
                "loadScript", "ss", (str(Path(sys.argv[1]).resolve()), PLUGIN))
            if script_id < 0:
                raise RuntimeError("KWin refused to load launch-origin")
            script = bus.get_object("org.kde.KWin", f"/Scripting/Script{script_id}")
            dbus.Interface(script, "org.kde.kwin.Script").run()
            print("Launch-origin KWin script loaded", flush=True)
        except (dbus.DBusException, RuntimeError) as error:
            print(f"Launch-origin waiting for KWin: {error}", file=sys.stderr, flush=True)
        return False

    def owner_changed(name, old, new):
        if name == "org.kde.KWin" and new:
            GLib.idle_add(load)

    bus.add_signal_receiver(owner_changed, signal_name="NameOwnerChanged",
                            dbus_interface="org.freedesktop.DBus", arg0="org.kde.KWin")

    def stop():
        try:
            scripting().unloadScript(PLUGIN)
        except dbus.DBusException:
            pass
        loop.quit()
        return False

    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, stop)
    GLib.idle_add(load)
    loop.run()
    service.remove_from_connection()


if __name__ == "__main__":
    main()
