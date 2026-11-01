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
import shlex
import shutil
import signal
import subprocess
import sys
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib, GLibUnix

import safeguards as sg


NAME = "org.nixos.KittyResurrect"
PLUGIN = "nixos-kitty-resurrect"
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "kitty-resurrect"
RUNTIME = Path(os.environ["XDG_RUNTIME_DIR"])
CLOSED_GRACE_MS = 30_000   # all windows gone this long with KWin alive = closed on purpose
CLAIM_TIMEOUT_MS = 60_000   # how long restored windows have to appear
KEEP_RETIRED = 10
GUARD = STATE / "guard.json"   # attempts + breaker, see safeguards.py


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


def loginctl(*args):
    try:
        return subprocess.run(["loginctl", *args], capture_output=True, text=True,
                              timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def graphical_session():
    return loginctl("show-user", str(os.getuid()), "-p", "Display", "--value")


def session_token():
    """Identifies one login: a new one closes the breaker and resets the cap."""
    try:
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except OSError:
        boot = ""
    return f"{boot}:{graphical_session()}"


def session_active():
    """logind's view of the graphical session; None when it cannot say.

    Inactive means a VT switch took DRM master away from KWin -- the state
    the 2026-10-31 black screens were in. Never restore into it.
    """
    sid = graphical_session()
    if not sid:
        return None
    return loginctl("show-session", sid, "-p", "Active", "--value") == "yes"


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
        self.pending = {}      # restore tag -> placement, until KWin claims it
        self.placed = set()    # tags kitty may drop again
        self.claimed = 0
        self.restoring = False
        self.closed_timer = None
        # Safeguards (docs/kitty-resurrect-safeguards.md).
        self.outputs = None    # KWin script's last output report
        self.outputs_changed = 0.0
        self.attempt_timer = None
        self.off_reason = None
        self.load_script = self.unload_script = lambda: None   # set by main()
        self.ledger = sg.Ledger(GUARD, log=log)
        self.ledger.begin_session(session_token())
        # kitty's file can trail a new window by one 5 s snapshot, so the
        # pairing that failed on KWin's update gets another go here.
        GLib.timeout_add_seconds(10, self.rematch)

    def off(self):
        """Kill switch, honored before any work. Logs and unloads once."""
        reason = sg.disabled(os.environ, sg.kill_file())
        if reason and not self.off_reason:
            log(f"kitty-resurrect: disabled ({reason}); KWin script unloaded, doing nothing")
            if self.attempt_timer is not None:
                GLib.source_remove(self.attempt_timer)
                self.attempt_timer = None
            self.unload_script()
        elif not reason and self.off_reason:
            log("kitty-resurrect: kill switch removed; loading the KWin script again")
            GLib.idle_add(self.load_script)
        self.off_reason = reason
        return reason is not None

    def rematch(self):
        if self.off():
            return True
        self.match_titles()
        self.save_placements()
        return True

    # ── KWin -> service ──
    @dbus.service.method(NAME, in_signature="s", out_signature="")
    def Update(self, payload):
        if self.off():
            return
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

    @dbus.service.method(NAME, in_signature="ss", out_signature="s")
    def Claim(self, window_id, tag):
        """KWin saw a window titled with a restore tag; hand it its place.

        Keyed by the tag kitty_snapshot.py puts in the title, never by launch
        order: one slow or failed launch used to shift every later window
        into its neighbour's place.
        """
        if self.off() or tag not in self.pending:
            return ""
        placement = self.pending.pop(tag)
        self.claimed += 1
        return json.dumps(placement) if placement else "{}"

    @dbus.service.method(NAME, in_signature="s", out_signature="")
    def Placed(self, tag):
        # kitty drops the tag and the title follows the shell again.
        self.placed.add(tag)
        unpin = RUNTIME / "kitty-resurrect-unpin"
        tmp = unpin.with_name("." + unpin.name)
        tmp.write_text("\n".join(sorted(self.placed)) + "\n")
        os.replace(tmp, unpin)

    @dbus.service.method(NAME, in_signature="i", out_signature="",
                         async_callbacks=("reply", "error"))
    def Delay(self, ms, reply, error):
        GLib.timeout_add(max(0, min(int(ms), 10_000)), lambda: reply() and False)

    @dbus.service.method(NAME, in_signature="s", out_signature="")
    def Outputs(self, payload):
        outputs = read_json_str(payload)
        if outputs is not None and outputs != self.outputs:
            self.outputs = outputs
            self.outputs_changed = time.monotonic()

    # ── kitty-resurrect CLI -> service ──
    @dbus.service.method(NAME, in_signature="s", out_signature="s")
    def Restore(self, path):
        # An explicit operator request skips the attempt cap and the breaker,
        # never the kill switch or the output check.
        if self.off():
            return f"disabled ({self.off_reason})"
        if self.restoring:
            return "a restore is already running"
        why = self.unhealthy()
        if why:
            return f"not now: {why}"
        target = Path(path) if path else self.newest_dead()
        if not target or not target.exists():
            return "nothing to restore"
        self.restore(target, retire_after=not path)
        return f"restoring {target}"

    @dbus.service.method(NAME, in_signature="", out_signature="s")
    def Reset(self):
        self.ledger.reset()
        return "breaker closed, attempts cleared"

    @dbus.service.method(NAME, in_signature="", out_signature="s")
    def Status(self):
        self.off()
        return json.dumps({"disabled": self.off_reason, "breaker": self.ledger.breaker,
                           "attempts": self.ledger.attempts, "max_attempts": sg.MAX_ATTEMPTS,
                           "restoring": self.restoring, "outputs": self.outputs,
                           "unhealthy": self.unhealthy()}, indent=1)

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

    # ── guarded automatic restore ──
    def unhealthy(self):
        return sg.outputs_unhealthy(self.outputs, session_active(),
                                    self.outputs_changed, time.monotonic())

    def check_restore(self):
        """KWin (re)started: schedule an attempt if a session died.

        Bounded by the ledger: a KWin crash loop calls this on every restart,
        and each call either waits out its backoff or is refused.
        """
        if self.off() or self.restoring or self.attempt_timer is not None:
            return False
        if not self.newest_dead():
            return False
        self.schedule(note="dead-session")
        return False

    def schedule(self, note):
        d = self.ledger.gate(time.time())
        if not d.allowed:
            log(sg.summary(d.attempt, sg.MAX_ATTEMPTS, "refused", d.reason, None))
            return
        log(sg.summary(d.attempt, sg.MAX_ATTEMPTS, "scheduled", note, d.delay))
        self.attempt_timer = GLib.timeout_add_seconds(d.delay, self.attempt)

    def attempt(self):
        self.attempt_timer = None
        if self.off() or self.restoring:
            return False
        d = self.ledger.gate(time.time())
        if not d.allowed:
            log(sg.summary(d.attempt, sg.MAX_ATTEMPTS, "refused", d.reason, None))
            return False
        target = self.newest_dead()
        if not target:
            return False
        self.ledger.start(time.time())
        why = self.unhealthy()
        if why:
            self.ledger.finish("skipped", time.time(), why)
            nxt = self.ledger.gate(time.time())
            log(sg.summary(d.attempt, sg.MAX_ATTEMPTS, "skipped", why,
                           nxt.delay if nxt.allowed else None))
            if nxt.allowed:
                self.attempt_timer = GLib.timeout_add_seconds(nxt.delay, self.attempt)
            return False
        log(sg.summary(d.attempt, sg.MAX_ATTEMPTS, "started", target.name, None))
        self.restore(target, retire_after=True, attempt=d.attempt)
        return False

    def kwin_restarted(self):
        """KWin went away mid-restore: that attempt failed (crash-loop signal)."""
        if self.restoring and self.ledger.attempts and \
                self.ledger.attempts[-1].get("outcome") == "started":
            self.ledger.finish("failed", time.time(), "kwin-restarted")
            log(sg.summary(len(self.ledger.attempts), sg.MAX_ATTEMPTS, "failed",
                           "kwin-restarted", None))

    def restore(self, target, retire_after, attempt=None):
        data = read_json(target, {})
        pid = data.get("pid")
        places = read_json(STATE / f"placement-{pid}.json", {}) if pid else {}
        windows = sorted(data.get("windows", []), key=lambda k: k["id"])
        if retire_after:
            retire(target)   # before launching: never restore the same state twice
        self.restoring = True
        self.pending, self.claimed = {}, 0
        self.cancel_closed()
        sessions = STATE / "restoring"
        shutil.rmtree(sessions, ignore_errors=True)
        sessions.mkdir(parents=True)
        stamp = int(time.time())

        for index, k in enumerate(windows):
            tag = f"kitty-resurrect:{stamp}:{index}"
            self.pending[tag] = places.get(str(k["id"]))
            path = sessions / f"{index}.kitty-session"
            path.write_text(tag_session(k["session"], tag))
            # A unit of its own: the kitty this starts must not live in this
            # unit's cgroup, or restarting the service would kill every
            # terminal. Named app-kitty@ like the dock's, so the template
            # drop-in (terminal priority, system/configuration.nix) applies;
            # a --scope could not carry that. A login shell gives it the
            # PATH the dock's kitty gets.
            subprocess.Popen(
                ["systemd-run", "--user", "--quiet", "--slice=app.slice",
                 f"--unit=app-kitty@resurrect-{time.time_ns()}", "--",
                 "bash", "-lc", 'exec kitty --single-instance --session "$1"', "kitty", str(path)],
                env=session_env(),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)

        def finish():
            if self.pending:
                log(f"{len(self.pending)} restored window(s) never claimed a place")
            if attempt is not None and self.ledger.attempts and \
                    self.ledger.attempts[-1].get("outcome") == "started":
                outcome = "failed" if self.pending else "ok"
                reason = f"unclaimed={len(self.pending)}" if self.pending else "all-claimed"
                self.ledger.finish(outcome, time.time(), reason)
                log(sg.summary(attempt, sg.MAX_ATTEMPTS, outcome, reason, None))
            self.restoring = False
            self.pending.clear()
            shutil.rmtree(sessions, ignore_errors=True)
            subprocess.Popen(["notify-send", "-a", "kitty", "-i", "kitty",
                              "Terminals restored",
                              f"{len(windows)} kitty window(s) from before the crash."])
            return False

        GLib.timeout_add(CLAIM_TIMEOUT_MS, finish)


def tag_session(session, tag):
    """Mark the OS window's first pane so kitty titles the window with `tag`."""
    lines = session.splitlines()
    for i, line in enumerate(lines):
        if line == "launch" or line.startswith("launch "):
            # A tag left over from an earlier restore would shadow the new one.
            words = [w for w in shlex.split(line)[1:] if not w.startswith("--var=kitty_resurrect=")]
            # kitty only recognises its unserialize data as the first argument.
            at = 1 if words and words[0].startswith("kitty-unserialize-data=") else 0
            words.insert(at, f"--var=kitty_resurrect={tag}")
            lines[i] = shlex.join(["launch"] + words)
            break
    return "\n".join(lines) + "\n"


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

    def unload():
        try:
            scripting().unloadScript(PLUGIN)
        except dbus.DBusException:
            pass

    def load():
        if service.off():
            return False
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
            service.kwin_restarted()
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

    service.load_script, service.unload_script = load, unload
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, stop)
    GLib.idle_add(load)
    loop.run()
    service.remove_from_connection()


if __name__ == "__main__":
    main()
