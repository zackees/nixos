# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""zoom-guard: pick Zoom's settings profile, and step down when it breaks.

Every forced Zoom setting here once fixed something and could itself break
Zoom; since the wrapper re-applies it at every start, a bad one would wedge
Zoom in a crash -> relaunch -> same setting loop. This keeps a ladder of
profiles, records hard failures, and steps down a rung (pinned 24 h, then one
probe back up) when the current rung keeps failing.

Hard failures only: an early exit, a crash, a unit restart, or llvmpipe
software rendering under a GPU profile. A clean quit never counts, so quitting
and relaunching quickly cannot demote. A black camera view cannot be told
apart from a camera that is switched off, so that case is manual:
`zoom-guard step-down`.

Never kills Zoom, never edits zoomus.conf while Zoom runs, and fails open:
the wrapper uses the rank-0 profile if this script errors or times out.

  pre            -> profile lines for the wrapper (ENV k v / CONF k v)
  watch UNIT     -> observe one Zoom run, record the outcome
  status | step-down | reset
"""

import fcntl
import json
import os
import subprocess
import sys
import time

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "zoom-guard")
STATE = os.path.join(STATE_DIR, "state.json")
DISABLE = os.path.expanduser("~/.config/zoom-guard/disable")

EGL = ("__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS",
       "/run/opengl-driver/share/egl/egl_external_platform.d")
OCL = ("OCL_ICD_VENDORS", "/run/opengl-driver/etc/OpenCL/vendors")
PROFILES = [
    {   # rank 0: GPU rendering via XWayland (native Wayland drew the camera
        # black on NVIDIA), GPU OpenCL effects.
        "name": "gpu-xwayland", "gpu": True,
        "env": [EGL, OCL],
        "conf": {"xwayland": "true", "enablegpucomputeutilization": "true",
                 "enablehardwareaccforvideosend": "true",
                 "enablehardwareaccforvideoreceive": "true"},
    },
    {   # rank 1 (floor): everything on the CPU, the configuration Zoom ran
        # in for months before the GPU work.
        "name": "safe-software", "gpu": False,
        "env": [("LIBGL_ALWAYS_SOFTWARE", "1")],
        "conf": {"xwayland": "true", "enablegpucomputeutilization": "false",
                 "enablehardwareaccforvideosend": "false",
                 "enablehardwareaccforvideoreceive": "false"},
    },
]
FLOOR = len(PROFILES) - 1
PIN_S = 24 * 3600
WINDOW_S = 10 * 60      # two failures at one rank within this demote
PRUNE_S = 30 * 60
EARLY_S = 60            # an exit sooner than this is a failure
GOOD_S = 120            # alive this long with no failure is a good run
FATAL_SIGNALS = {"SEGV", "ABRT", "BUS", "ILL", "FPE"}


# ── pure logic ──────────────────────────────────────────────────────────

def empty() -> dict:
    return {"v": 1, "rank": 0, "pinned_until": 0, "good_at": None, "failures": []}


def valid(state) -> dict:
    if not isinstance(state, dict) or state.get("v") != 1:
        return empty()
    base = empty()
    base.update({k: state[k] for k in base if k in state})
    if not isinstance(base["rank"], int) or not 0 <= base["rank"] <= FLOOR:
        base["rank"] = 0
    return base


def decide(state: dict, now: float) -> tuple[int, bool]:
    """Rank to start with, and whether this start is a probe back up."""
    if state["rank"] > 0 and now >= state["pinned_until"]:
        return 0, True
    return state["rank"], False


def classify(props: dict, lived_s: float) -> str | None:
    """Failure reason for a finished Zoom unit, or None for a clean run."""
    if int(props.get("NRestarts") or 0) > 0:
        return "restart"
    result = props.get("Result", "success")
    code = props.get("ExecMainCode", "")      # exited | killed | dumped
    status = str(props.get("ExecMainStatus", "0"))
    if result == "core-dump" or code == "dumped":
        return "crash"
    if code == "killed" and status in FATAL_SIGNALS:
        return "crash"
    if result == "success" or (code == "killed" and status in {"TERM", "HUP", "INT", "KILL"}):
        return None                            # the user quit
    return "early-exit" if lived_s < EARLY_S else None


def record(state: dict, rank: int, why: str | None, now: float,
           lived_s: float = GOOD_S) -> tuple[dict, str]:
    """Fold one run's outcome into the state; returns (state, action)."""
    s = valid(json.loads(json.dumps(state)))
    s["failures"] = [f for f in s["failures"] if now - f["t"] < PRUNE_S]
    if why is None:
        if lived_s >= GOOD_S:
            s["good_at"] = now
            s["failures"] = [f for f in s["failures"] if f["rank"] != rank]
            if rank < s["rank"]:               # a probe back up worked
                s["rank"], s["pinned_until"] = rank, 0
                return s, "promoted"
        return s, "ok"
    s["failures"].append({"t": now, "rank": rank, "why": why})
    recent = [f for f in s["failures"] if f["rank"] == rank and now - f["t"] < WINDOW_S]
    if why == "llvmpipe" or len(recent) >= 2:
        if rank >= FLOOR:
            return s, "floor"
        s["rank"], s["pinned_until"] = rank + 1, now + PIN_S
        return s, "demoted"
    return s, "counted"


def step_down(state: dict, now: float) -> tuple[dict, str]:
    s = valid(state)
    if s["rank"] >= FLOOR:
        return s, "floor"
    s["rank"], s["pinned_until"] = s["rank"] + 1, now + PIN_S
    return s, "demoted"


# ── I/O shell ───────────────────────────────────────────────────────────

def load() -> dict:
    try:
        with open(STATE) as f:
            return valid(json.load(f))
    except (OSError, ValueError):
        return empty()


def save(state: dict) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, indent=1)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, STATE)


def say(msg: str, urgent: bool = False) -> None:
    print(f"zoom-guard: {msg}", file=sys.stderr, flush=True)
    try:
        subprocess.run(["notify-send", "-a", "Zoom guard", "-u",
                        "critical" if urgent else "normal", "Zoom", msg],
                       timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def unit_props(unit: str) -> dict:
    out = subprocess.run(
        ["systemctl", "--user", "show", unit, "-p",
         "ActiveState,Result,ExecMainCode,ExecMainStatus,NRestarts,MainPID"],
        capture_output=True, text=True, timeout=10).stdout
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def uses_llvmpipe(pid: str) -> bool:
    try:
        for t in os.listdir(f"/proc/{pid}/task"):
            with open(f"/proc/{pid}/task/{t}/comm") as f:
                if f.read().startswith("llvmpipe"):
                    return True
    except OSError:
        pass
    return False


def cmd_pre() -> None:
    if os.path.exists(DISABLE) or os.environ.get("ZOOM_GUARD") == "off":
        print("PROFILE none")
        return
    state = load()
    rank, probe = decide(state, time.time())
    p = PROFILES[rank]
    print(f"PROFILE {p['name']} {rank}")
    for k, v in p["env"]:
        print(f"ENV {k} {v}")
    for k, v in p["conf"].items():
        print(f"CONF {k} {v}")
    if probe:
        say(f"retrying {p['name']} after a 24 h fallback. If it misbehaves "
            "(black video, crashes), run: zoom-guard step-down")
    elif rank > 0:
        say(f"started with fallback profile {p['name']}; "
            "`zoom-guard reset` returns to the GPU profile")


def cmd_watch(unit: str, rank: int) -> None:
    started = time.time()
    why = None
    for at in (20, 60, GOOD_S):
        time.sleep(max(0, started + at - time.time()))
        props = unit_props(unit)
        if props.get("ActiveState") != "active":
            break
        if PROFILES[rank]["gpu"] and at >= 60 and uses_llvmpipe(props.get("MainPID", "0")):
            why = "llvmpipe"
            break
    while why is None and unit_props(unit).get("ActiveState") == "active":
        time.sleep(15)
    lived = time.time() - started
    if why is None:
        why = classify(unit_props(unit), lived)
    state, action = record(load(), rank, why, time.time(), lived)
    save(state)
    name = PROFILES[rank]["name"]
    print(f"zoom-guard: {unit} rank={rank} lived={lived:.0f}s why={why} -> {action}",
          file=sys.stderr, flush=True)
    if action == "demoted":
        say(f"{name} failed ({why}); next Zoom start uses "
            f"{PROFILES[state['rank']]['name']} for 24 h", urgent=True)
    elif action == "floor":
        say(f"Zoom is failing even with {name} ({why}); "
            "the guard has no lower profile. See journalctl --user -t zoom-guard",
            urgent=True)
    elif action == "promoted":
        say(f"{name} works again; it is the default once more")


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "pre":
        cmd_pre()
    elif cmd == "watch":
        cmd_watch(argv[2], int(argv[3]))
    elif cmd == "step-down":
        state, action = step_down(load(), time.time())
        save(state)
        print(f"{action}: next Zoom start uses {PROFILES[state['rank']]['name']} "
              "(restart Zoom when you can)")
    elif cmd == "reset":
        save(empty())
        print(f"reset: next Zoom start uses {PROFILES[0]['name']}")
    elif cmd == "status":
        s = load()
        print(json.dumps({"profile": PROFILES[s["rank"]]["name"], **s}, indent=1))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
