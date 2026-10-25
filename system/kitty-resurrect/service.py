"""Bring kitty's OS windows back after a crash, each on its own screen and desktop.

Three parts, because no one of them knows everything:
  kitty_snapshot.py  inside kitty: every OS window as a session (tabs, splits,
                     directories, what each shell runs) -> kitty-<pid>.json
  main.js            inside KWin: where each kitty window is (screen, desktop,
                     geometry), and placing the windows a restore creates
  this service       pairs the two up -> placement-<pid>.json, and restores

A kitty-<pid>.json whose process is gone is a session that died under the user
-- a KWin crash, a reboot -- and is restored once, the next time KWin starts
the script. Closing every window deliberately is not: the service sees the
kitty windows go away with KWin still up and retires the state instead.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib, GLibUnix


NAME = "org.nixos.KittyResurrect"
PLUGIN = "nixos-kitty-resurrect"
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "kitty-resurrect"
RUNTIME = Path(os.environ["XDG_RUNTIME_DIR"])
CLOSED_GRACE_MS = 30_000   # all windows gone this long with KWin alive = closed on purpose
CLAIM_TIMEOUT_MS = 15_000
KEEP_RETIRED = 10


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(".tmp-" + path.name)
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


def kitty_alive(pid):
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip() in (".kitty-wrapped", "kitty")
    except OSError:
        return False


def session_env():
    """The graphical session's environment as it is now, not at service start.

    This unit can start before Plasma imports WAYLAND_DISPLAY into the user
    manager, and kitty keys its --single-instance socket on the display: a
    kitty started without it never finds the running one, cannot open a
    window of its own either, and the restore silently produces nothing.
    """
    env = dict(os.environ)
    try:
        out = subprocess.run(["systemctl", "--user", "show-environment"],
                             capture_output=True, text=True, timeout=5).stdout
        env.update(line.split("=", 1) for line in out.splitlines() if "=" in line)
    except (OSError, subprocess.SubprocessError):
        pass
    return env


def retire(path):
    """Keep a few old states for a manual `kitty-resurrect restore FILE`."""
    retired = STATE / "retired"
    retired.mkdir(parents=True, exist_ok=True)
    pid = path.stem.split("-", 1)[1]
    for name in (f"kitty-{pid}.json", f"placement-{pid}.json"):
        if (STATE / name).exists():
            os.replace(STATE / name, retired / name)
    old = sorted(retired.glob("kitty-*.json"), key=lambda p: p.stat().st_mtime)
    for stale in old[:-KEEP_RETIRED]:
        for name in (stale.name, stale.name.replace("kitty-", "placement-", 1)):
            try:
                (retired / name).unlink()
            except OSError:
                pass


class Service(dbus.service.Object):
    def __init__(self, bus):
        self.name = dbus.service.BusName(NAME, bus=bus, do_not_queue=True)
        super().__init__(self.name, "/org/nixos/KittyResurrect")
        self.windows = []      # KWin's latest view of the kitty windows
        self.mapping = {}      # KWin internalId -> (kitty pid, os window id)
        self.pending = []      # placements handed out in launch order
        self.claimed = 0
        self.restoring = False
        self.closed_timer = None
        # kitty's file can trail a new window by one 5 s snapshot, so the
        # pairing that failed on KWin's update gets another go here.
        GLib.timeout_add_seconds(10, self.rematch)

    def rematch(self):
        self.match_titles()
        self.save_placements()
        return True

    # ── KWin -> service ──
    @dbus.service.method(NAME, in_signature="s", out_signature="")
    def Update(self, payload):
        windows = read_json_str(payload)
        if windows is None:
            return
        self.windows = windows
        live = {w["id"] for w in windows}
        self.mapping = {k: v for k, v in self.mapping.items() if k in live}
        for w in windows:
            if w.get("active"):
                # kitty publishes its focused OS window every 0.5 s.
                GLib.timeout_add(700, self.learn_focus, w["id"], w["pid"])
        self.match_titles()
        self.save_placements()
        if windows:
            self.cancel_closed()
        elif self.closed_timer is None and not self.restoring:
            self.closed_timer = GLib.timeout_add(CLOSED_GRACE_MS, self.closed_on_purpose)

    @dbus.service.method(NAME, in_signature="s", out_signature="s")
    def Claim(self, window_id):
        if not self.restoring or not self.pending:
            return ""
        placement = self.pending.pop(0)
        self.claimed += 1
        return json.dumps(placement) if placement else ""

    @dbus.service.method(NAME, in_signature="i", out_signature="",
                         async_callbacks=("reply", "error"))
    def Delay(self, ms, reply, error):
        GLib.timeout_add(max(0, min(int(ms), 10_000)), lambda: reply() and False)

    # ── kitty-resurrect CLI -> service ──
    @dbus.service.method(NAME, in_signature="s", out_signature="s")
    def Restore(self, path):
        if self.restoring:
            return "a restore is already running"
        target = Path(path) if path else self.newest_dead()
        if not target or not target.exists():
            return "nothing to restore"
        self.restore(target, retire_after=not path)
        return f"restoring {target}"

    # ── pairing KWin windows with kitty OS windows ──
    def learn_focus(self, window_id, pid):
        active = next((w for w in self.windows if w.get("active")), None)
        if active and active["id"] == window_id:
            try:
                os_id = int((RUNTIME / f"kitty-resurrect-focus-{pid}").read_text())
            except (OSError, ValueError):
                return False
            # One OS window belongs to one KWin window at a time.
            self.mapping = {k: v for k, v in self.mapping.items() if v != (pid, os_id)}
            self.mapping[window_id] = (pid, os_id)
            self.save_placements()
        return False

    def match_titles(self):
        """Fill gaps the focus pairing has not reached yet, where unambiguous."""
        for pid in {w["pid"] for w in self.windows}:
            state = read_json(STATE / f"kitty-{pid}.json", {})
            taken = {v[1] for v in self.mapping.values() if v[0] == pid}
            kitty = [k for k in state.get("windows", []) if k["id"] not in taken]
            kwin = [w for w in self.windows if w["pid"] == pid and w["id"] not in self.mapping]
            if len(kitty) == len(kwin) and kwin:
                # Both sides are the same set of open windows. The ones KWin
                # numbered were created after the rest, so they are the
                # highest kitty ids, in the same order.
                kitty_ids = sorted(k["id"] for k in kitty)
                numbered = sorted((w for w in kwin if w.get("seq", -1) >= 0), key=lambda w: w["seq"])
                unnumbered = [w for w in kwin if w.get("seq", -1) < 0]
                for w, os_id in zip(numbered, kitty_ids[len(unnumbered):]):
                    self.mapping[w["id"]] = (pid, os_id)
                if len(unnumbered) == 1:
                    self.mapping[unnumbered[0]["id"]] = (pid, kitty_ids[0])
                kitty = [k for k in kitty if k["id"] in kitty_ids[:len(unnumbered)]]
                kwin = unnumbered
            for w in kwin:
                same = [k for k in kitty if k["title"] == w["caption"]]
                rivals = [o for o in kwin if o["caption"] == w["caption"]]
                if len(same) == 1 and len(rivals) == 1:
                    self.mapping[w["id"]] = (pid, same[0]["id"])

    def save_placements(self):
        by_pid = {}
        for w in self.windows:
            if w["id"] in self.mapping:
                pid, os_id = self.mapping[w["id"]]
                place = {k: w.get(k) for k in ("output", "desktops", "x", "y", "width", "height", "minimized", "tile")}
                by_pid.setdefault(pid, {})[str(os_id)] = place
        for pid, places in by_pid.items():
            path = STATE / f"placement-{pid}.json"
            old = read_json(path, {})
            if {**old, **places} != old:
                write_json(path, {**old, **places})

    # ── deliberate close vs. crash ──
    def cancel_closed(self):
        if self.closed_timer is not None:
            GLib.source_remove(self.closed_timer)
            self.closed_timer = None

    def closed_on_purpose(self):
        self.closed_timer = None
        if not self.windows:
            for state in STATE.glob("kitty-*.json"):
                pid = read_json(state, {}).get("pid")
                if pid and not kitty_alive(pid):
                    log(f"kitty {pid} closed with KWin running; not restoring it")
                    retire(state)
        return False

    # ── restore ──
    def newest_dead(self):
        dead = []
        for state in STATE.glob("kitty-*.json"):
            data = read_json(state, {})
            if data.get("pid") and not kitty_alive(data["pid"]) and data.get("windows"):
                dead.append((data.get("time", 0), state))
        dead.sort()
        # Only the newest is the session that was lost; older ones are history.
        for _, older in dead[:-1]:
            retire(older)
        return dead[-1][1] if dead else None

    def check_restore(self):
        target = self.newest_dead()
        if target and not self.restoring:
            log(f"restoring {target}")
            self.restore(target, retire_after=True)
        return False

    def restore(self, target, retire_after):
        data = read_json(target, {})
        pid = data.get("pid")
        places = read_json(STATE / f"placement-{pid}.json", {}) if pid else {}
        windows = sorted(data.get("windows", []), key=lambda k: k["id"])
        if retire_after:
            retire(target)   # before launching: never restore the same state twice
        self.restoring = True
        self.pending, self.claimed = [], 0
        self.cancel_closed()
        sessions = STATE / "restoring"
        shutil.rmtree(sessions, ignore_errors=True)
        sessions.mkdir(parents=True)

        def launch(index):
            if index == len(windows):
                return finish()
            k = windows[index]
            path = sessions / f"{index}.kitty-session"
            path.write_text(k["session"])
            self.pending.append(places.get(str(k["id"])))
            expect = self.claimed + 1
            # A scope of its own: the kitty this starts must not live in this
            # unit's cgroup, or restarting the service would kill every
            # terminal. A login shell gives it the PATH the dock's kitty gets.
            subprocess.Popen(
                ["systemd-run", "--user", "--scope", "--quiet", "--slice=app.slice", "--",
                 "bash", "-lc", 'exec kitty --single-instance --session "$1"', "kitty", str(path)],
                env=session_env(),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            waited = {"ms": 0}

            def wait():
                waited["ms"] += 100
                if self.claimed >= expect or waited["ms"] >= CLAIM_TIMEOUT_MS:
                    if self.claimed < expect:
                        log(f"window {index} never appeared; continuing")
                        self.pending.clear()
                    launch(index + 1)
                    return False
                return True
            GLib.timeout_add(100, wait)
            return False

        def finish():
            self.restoring = False
            self.pending.clear()
            shutil.rmtree(sessions, ignore_errors=True)
            subprocess.Popen(["notify-send", "-a", "kitty", "-i", "kitty",
                              "Terminals restored",
                              f"{len(windows)} kitty window(s) from before the crash."])
            return False

        launch(0)


def read_json_str(payload):
    try:
        value = json.loads(payload)
    except (TypeError, ValueError):
        return None
    return value if isinstance(value, list) else None


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
            scripting().unloadScript(PLUGIN)
            # Same two-argument overload trap as launch-origin's service.py.
            script_id = bus.call_blocking(
                "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting",
                "loadScript", "ss", (str(Path(sys.argv[1]).resolve()), PLUGIN))
            if script_id < 0:
                raise RuntimeError("KWin refused to load kitty-resurrect")
            script = bus.get_object("org.kde.KWin", f"/Scripting/Script{script_id}")
            dbus.Interface(script, "org.kde.kwin.Script").run()
            log("kitty-resurrect KWin script loaded")
            # Give the rest of the session a moment to come up first.
            GLib.timeout_add_seconds(5, service.check_restore)
        except (dbus.DBusException, RuntimeError) as error:
            log(f"kitty-resurrect waiting for KWin: {error}")
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
