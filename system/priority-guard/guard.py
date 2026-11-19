# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Keep calls and the desktop ahead of builds, whoever started them.

Every few seconds, as root:

- Zoom: every thread to nice -10. The session cannot raise priority itself
  (DefaultLimitNICE=0), and a Zoom launched from an agent's browser inherits
  nice 19. A correction to a Zoom outside an app-Zoom@ unit is logged as a
  WARNING: it means a launch path got past the wrapper. Inside the unit,
  some of Zoom's new threads still start at 0, so those are fixed quietly.
- Agents: every process descended from an agent harness (clud, claude,
  codex) to nice 19. The harness used to start sessions at 19 itself, and
  this file relied on that; by 2026-11-19 every session ran at 0, so each
  compiler an agent spawned ran at normal priority until the next scan
  caught it, and short ones finished first. Zoom sat 17-20% of the time
  waiting for CPU. Renicing the whole tree means later children are born at
  19, and the rule below makes them SCHED_IDLE.
- Spectacle (screenshots): every thread to nice -10 as well, silently. A
  capture under a saturated box stalled or timed out at nice 0, and a user
  unit cannot lower its own nice (DefaultLimitNICE=0), so only root can make
  this stick. Its unit also carries CPUWeight=1000 (priority-guard.nix),
  which covers the first seconds before this loop reaches it.
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
# Agent harnesses: everything under one of these is batch work.
AGENTS = {"clud", "claude", "codex"}
NICE_AGENT = 19


def comm(path: str) -> str:
    with open(f"{path}/comm") as f:  # io-ok: root daemon, not kitty
        return f.read().strip()


def boost_spectacle(uid: int) -> None:
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        base = f"/proc/{pid}"
        try:
            if comm(base) != ".spectacle-wrap" or os.stat(base).st_uid != uid:
                continue
            for t in os.listdir(f"{base}/task"):
                tid = int(t)
                if os.sched_getscheduler(tid) == os.SCHED_IDLE:
                    os.sched_setscheduler(tid, os.SCHED_OTHER, os.sched_param(0))
                if os.getpriority(os.PRIO_PROCESS, tid) > NICE_ZOOM:
                    os.setpriority(os.PRIO_PROCESS, tid, NICE_ZOOM)
        except OSError:
            continue


def scan(uid: int) -> dict[int, tuple[int, str, bool]]:
    """pid -> (ppid, comm, owned by uid), for every live process."""
    procs = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        base = f"/proc/{pid}"
        try:
            with open(f"{base}/stat") as f:  # io-ok: root daemon, not kitty
                stat = f.read()
            mine = os.stat(base).st_uid == uid
        except OSError:
            continue
        # comm sits in parentheses and may itself contain ") ".
        name = stat[stat.index("(") + 1:stat.rindex(")")]
        ppid = int(stat[stat.rindex(")") + 2:].split()[1])
        procs[int(pid)] = (ppid, name, mine)
    return procs


def agent_tree(procs: dict[int, tuple[int, str, bool]]) -> set[int]:
    """The user's processes that are, or descend from, an agent harness."""
    memo: dict[int, bool] = {}

    def under(pid: int) -> bool:
        chain = []
        while pid > 1 and pid in procs and pid not in memo:
            ppid, name, mine = procs[pid]
            if mine and name in AGENTS:
                memo[pid] = True
                break
            chain.append(pid)
            pid = ppid
        hit = memo.get(pid, False)
        for c in chain:
            memo[c] = hit
        return hit

    return {pid for pid, (_, _, mine) in procs.items() if mine and under(pid)}


def main() -> None:
    uid = pwd.getpwnam(USER).pw_uid
    while True:
        zoom_fixed = 0
        procs = scan(uid)
        agents = agent_tree(procs)
        for pid, (_, name, mine) in procs.items():
            base = f"/proc/{pid}"
            # By the process's name, not each thread's: a daemon's workers
            # are called tokio-rt-worker and the like.
            tool = name in BUILD_TOOLS
            if not (mine or tool):
                continue  # build tools are batch whoever runs them
            try:
                exe = os.readlink(f"{base}/exe")
                tids = os.listdir(f"{base}/task")
                with open(f"{base}/cgroup") as f:  # io-ok: root daemon, not kitty
                    cgroup = f.read()
            except OSError:
                continue
            is_zoom = mine and exe.startswith("/opt/zoom/")
            is_snap = mine and "-spectacle-" in exe
            is_agent = pid in agents and not (is_zoom or is_snap)
            for t in tids:
                tid = int(t)
                try:
                    ni = os.getpriority(os.PRIO_PROCESS, tid)
                    if is_zoom:
                        if ni > NICE_ZOOM:
                            os.setpriority(os.PRIO_PROCESS, tid, NICE_ZOOM)
                            if "/app-Zoom@" not in cgroup:
                                zoom_fixed += 1
                        continue
                    if is_snap:
                        if os.sched_getscheduler(tid) == os.SCHED_IDLE:
                            os.sched_setscheduler(tid, os.SCHED_OTHER, os.sched_param(0))
                        if ni > NICE_ZOOM:
                            os.setpriority(os.PRIO_PROCESS, tid, NICE_ZOOM)
                        continue
                    if is_agent and ni < NICE_AGENT:
                        os.setpriority(os.PRIO_PROCESS, tid, NICE_AGENT)
                        ni = NICE_AGENT
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
            print(f"WARNING: reniced {zoom_fixed} Zoom threads to {NICE_ZOOM} "
                  "outside app-Zoom@; a launch path bypassed the wrapper",
                  file=sys.stderr, flush=True)
        # Between full scans, re-check only for Spectacle every 0.5 s: a
        # capture lasts a few seconds, so a 3 s wait for nice -10 is most of it.
        for _ in range(int(INTERVAL / 0.5)):
            time.sleep(0.5)
            boost_spectacle(uid)


if __name__ == "__main__":
    main()
