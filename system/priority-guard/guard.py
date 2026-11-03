# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Keep calls and the desktop ahead of builds, whoever started them.

Every few seconds, as root:

- Zoom: every thread to nice -10. The session cannot raise priority itself
  (DefaultLimitNICE=0), and a Zoom launched from an agent's browser inherits
  nice 19. Each correction is logged as a WARNING: it means a launch path got
  past the app-Zoom@ wrapper.
- Batch work: SCHED_IDLE for the user's threads at nice >= 10 (agents run at
  19, build scopes at 10) and for known build tools at any nice, which also
  get at least nice 10. Nice and CPUWeight only shrink a build's share; a
  runnable build still takes a full slice on every CPU before a Zoom click is
  served, and with 150 runnable threads that was a call you could not click
  in (2026-11-02). SCHED_IDLE threads run only when nothing else wants the
  CPU, so an idle machine still gives builds every core. Children inherit the
  policy at fork, so catching a make/cargo parent covers its whole tree.
"""

import os
import pwd
import sys
import time

USER = "niteris"
NICE_ZOOM = -10
NICE_BUILD = 10
INTERVAL = 3.0
# Container builds. Declared CPUWeight=idle in configuration.nix, but a
# `systemctl set-property bosn.slice CPUWeight=10` (no --runtime) from any
# tool writes /etc/systemd/system.control, outranks the declared unit, and
# silently turned it back into a mere low weight once already.
IDLE_SLICES = ["/sys/fs/cgroup/bosn.slice/cpu.idle"]
# comm names (truncated to 15 chars by the kernel)
BUILD_TOOLS = {
    "cc", "cc1", "cc1plus", "cc1obj", "gcc", "g++", "c++", "clang", "clang++",
    "ld", "ld.lld", "ld.bfd", "ld.gold", "lld", "mold", "collect2", "as",
    "rustc", "cargo", "clippy-driver", "rustdoc", "build-script-b",
    "make", "gmake", "ninja", "cmake", "meson",
    "soldr", "soldr-daemon", "zccache", "zccache-daemon", "sccache",
    "buildkitd", "docker-buildx", "act", "bosn-daemon",
    "fbuild", "fbuild-daemon", "pytest",
}


def comm(path: str) -> str:
    with open(f"{path}/comm") as f:  # io-ok: root daemon, not kitty
        return f.read().strip()


def main() -> None:
    uid = pwd.getpwnam(USER).pw_uid
    while True:
        zoom_fixed = 0
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            base = f"/proc/{pid}"
            try:
                mine = os.stat(base).st_uid == uid
                # By the process's name, not each thread's: a daemon's
                # workers are called tokio-rt-worker and the like.
                tool = comm(base) in BUILD_TOOLS
                if not (mine or tool):
                    continue  # build tools are batch whoever runs them
                exe = os.readlink(f"{base}/exe")
                tids = os.listdir(f"{base}/task")
            except OSError:
                continue
            is_zoom = mine and exe.startswith("/opt/zoom/")
            for t in tids:
                tid = int(t)
                try:
                    ni = os.getpriority(os.PRIO_PROCESS, tid)
                    if is_zoom:
                        if ni > NICE_ZOOM:
                            os.setpriority(os.PRIO_PROCESS, tid, NICE_ZOOM)
                            zoom_fixed += 1
                        continue
                    if os.sched_getscheduler(tid) != os.SCHED_OTHER:
                        continue  # already idle/batch, or real-time audio
                    if tool and ni < NICE_BUILD:
                        os.setpriority(os.PRIO_PROCESS, tid, NICE_BUILD)
                        ni = NICE_BUILD
                    if tool or (mine and ni >= NICE_BUILD):
                        os.sched_setscheduler(tid, os.SCHED_IDLE, os.sched_param(0))
                except OSError:
                    continue  # thread exited mid-scan
        for path in IDLE_SLICES:
            try:
                with open(path) as f:  # io-ok: root daemon, not kitty
                    if f.read().strip() == "1":
                        continue
                with open(path, "w") as f:  # io-ok: root daemon, not kitty
                    f.write("1")
                print(f"WARNING: {path} was not idle; something overrode "
                      "CPUWeight=idle (check /etc/systemd/system.control)",
                      file=sys.stderr, flush=True)
            except OSError:
                pass  # slice not created yet
        if zoom_fixed:
            print(f"WARNING: reniced {zoom_fixed} Zoom threads to {NICE_ZOOM}; "
                  "a launch path bypassed app-Zoom@", file=sys.stderr, flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
