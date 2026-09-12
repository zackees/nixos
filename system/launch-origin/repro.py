"""Live regression: opens temporary test terminals, then closes only those.

Run after activation with python3 system/launch-origin/repro.py [--shared].
Optional --source-position X Y and --observer-position X Y exercise monitors.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time


def kd(*args):
    return subprocess.check_output(["kdotool", *map(str, args)], text=True).strip()


def wait_window(cls):
    for _ in range(80):
        result = kd("search", "--class", "^" + cls + "$")
        if result:
            return result.splitlines()[0]
        time.sleep(0.1)
    raise RuntimeError("Test window did not appear: " + cls)


def info(window):
    raw = subprocess.check_output([
        "qdbus", "org.kde.KWin", "/KWin", "org.kde.KWin.getWindowInfo", window], text=True)
    return dict(line.split(": ", 1) for line in raw.splitlines() if ": " in line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shared", action="store_true")
    parser.add_argument("--source-position", nargs=2, type=int)
    parser.add_argument("--observer-position", nargs=2, type=int)
    args = parser.parse_args()
    prior = kd("getactivewindow")
    prefix = f"launch-origin-test-{os.getpid()}-"
    classes = [prefix + part for part in ("observer", "source", "child", "decoy")]
    processes = []
    with tempfile.TemporaryDirectory(prefix="launch-origin-test-") as temporary:
        gate = Path(temporary) / "ready"
        socket = "unix:" + str(Path(temporary) / "kitty.sock")

        def launch(cls, *command, extra=()):
            process = subprocess.Popen([
                "kitty", "--class", cls, "-o", "confirm_os_window_close=0",
                *extra, *command], start_new_session=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(process)
            return wait_window(cls)

        try:
            observer = launch(classes[0], "sleep", "45")
            if args.observer_position:
                kd("windowmove", observer, *args.observer_position)
            kd("windowactivate", observer)
            active = kd("get_desktop")
            source_desktop = "6" if active != "6" else "5"
            command = ["sh", "-c",
                       'while [ ! -f "$1" ]; do sleep 0.05; done; '
                       'kitty --class "$2" -o confirm_os_window_close=0 sleep 20',
                       "sh", str(gate), classes[2]]
            if args.shared:
                decoy = launch(classes[3], "sleep", "45", extra=(
                    "--listen-on", socket, "-o", "allow_remote_control=socket-only"))
                subprocess.run([
                    "kitty", "@", "--to", socket, "launch", "--type=os-window",
                    "--os-window-class", classes[1], "--os-window-title", classes[1],
                    "--title", classes[1], *command], check=True, stdout=subprocess.DEVNULL)
                source = wait_window(classes[1])
                if kd("getwindowpid", source) != kd("getwindowpid", decoy):
                    raise RuntimeError("Shared-process fixture did not share a PID")
            else:
                source = launch(classes[1], *command)
            if args.source_position:
                kd("windowmove", source, *args.source_position)
            kd("set_desktop_for_window", source, source_desktop)
            kd("windowactivate", observer)
            time.sleep(0.7)  # allow the kitty metadata heartbeat to publish
            before = info(source)
            gate.touch()
            child = wait_window(classes[2])
            time.sleep(0.8)
            after = info(child)
            membership = before.get("desktops") == after.get("desktops")
            focus = kd("getactivewindow") == observer
            desktop = kd("get_desktop") == active
            # KWin places the child relative to the source monitor; compare
            # its position with that monitor's bounds when testing this host.
            monitor = True
            if args.source_position == [20, 850]:
                monitor = 0 <= float(after["x"]) < 1463 and float(after["y"]) >= 823
            print(f"shared={args.shared} source-desktop={source_desktop} "
                  f"child-membership={membership} focus-preserved={focus} "
                  f"active-desktop-preserved={desktop} monitor-correct={monitor}")
            if not all((membership, focus, desktop, monitor)):
                raise SystemExit(1)
        finally:
            for cls in reversed(classes):
                for window in kd("search", "--class", "^" + cls + "$").splitlines():
                    subprocess.run(["kdotool", "windowclose", window], check=False)
            for process in processes:
                process.wait(timeout=10)
            if prior:
                subprocess.run(["kdotool", "windowactivate", prior], check=False)


if __name__ == "__main__":
    main()
