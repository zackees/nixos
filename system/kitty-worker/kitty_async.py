"""kitty's half of kitty-worker: ask, never wait.

Runs on kitty's main thread, which draws every terminal, so it must not
block: no file or /proc access after install, only running-process's
non-blocking service client (running_process_service) and in-memory reads
of the last reply. Its send() refuses at once when the worker is down or
behind, and replies are collected by polling try_recv() from a timer. A
dead or slow worker costs stale labels, never a frozen terminal.

    client = get()            # the one Client, kept on kitty's boss
    with client.offline():    # kitty's /proc lookups answered from the cache
        exe = window.get_exe_of_child()
    client.branch(wd)         # '' until the worker has answered
    client.write(path, text)  # atomic write, done by the worker
    client.read(path)         # ask; client.files[path] holds the answer later
    client.request(msg, f)    # f(reply) runs on kitty's thread when it arrives
    client.listeners.append(f)  # called after each reply

Loaded by tab_bar.py, including on SIGUSR1; install() replaces the timers
and keeps the connection, which lives on the boss with the cached state.
The service client's own thread finds the worker, health-probes it, and if
it is gone asks systemd to start it -- none of that on kitty's thread.
"""

import json
import os
import sys
from contextlib import contextmanager

# The running-process wheel packaged by system/kitty-worker.nix, pinned to the
# release worker.py names. Importing it loads the native extension only.
_SITE = "/run/current-system/sw/share/kitty-worker/site"
if _SITE not in sys.path:
    sys.path.insert(0, _SITE)
# io-ok: one import at module load (kitty start / SIGUSR1), not on a timer or draw
import running_process_service as rps

PANES_INTERVAL = 0.5
POLL_INTERVAL = 0.05
MAX_REPLIES_PER_TICK = 256

SPEC = rps.ServiceSpec(
    name="kitty-worker",
    version="2",
    payload_protocol=0xF0B7,  # private use: one machine, not registered
    # systemd supervises the worker; a client that finds it gone asks systemd
    # rather than starting a second, unsupervised copy.
    command=["/run/current-system/sw/bin/systemctl", "--user", "start", "kitty-worker.service"],
    health_interval=2.0,
    spawn_budget=(3, 30.0),
)


class Client:
    def __init__(self, boss, service=None):
        self.boss = boss
        self.procs = {}       # pid -> {cmdline, cwd, exe}, from the last reply
        self.branches = {}    # dir -> branch
        self.files = {}       # path -> text (None: missing), from read()
        self.listeners = []
        self.pending = {}     # request id -> callback(reply)
        self.service = service or rps.ServiceClient.connect(SPEC, queue_depth=256)

    def close(self):
        self.service.close()

    def send(self, msg, on_reply=None):
        try:
            rid = self.service.send(json.dumps(msg).encode())
        except (rps.ServiceUnavailable, rps.QueueFull):
            return  # worker down or behind: drop, the next tick resends
        if on_reply is not None:
            self.pending[rid] = on_reply
            if len(self.pending) > 128:  # replies that will never come
                self.pending.pop(min(self.pending))

    def write(self, path, text):
        self.send({"op": "write", "path": str(path), "text": text})

    def delete(self, path):
        self.send({"op": "unlink", "path": str(path)})

    def request(self, msg, callback):
        self.send(msg, callback)

    def read(self, path):
        self.send({"op": "read", "path": str(path)}, self._on_read)

    def branch(self, wd):
        return self.branches.get(wd, "")

    def _on_read(self, msg):
        self.files[msg.get("path")] = msg.get("text")

    def _on_panes(self, msg):
        self.procs = {int(k): v for k, v in msg.get("procs", {}).items()}
        self.branches.update(msg.get("branches", {}))
        if len(self.branches) > 256:
            self.branches = dict(msg.get("branches", {}))
        self._panes_arrived = True

    def request_panes(self, _timer_id=None):
        from kitty.window import path_from_osc7_url
        panes = []
        for w in list(self.boss.window_id_map.values()):
            child = w.child
            try:
                pgid = os.tcgetpgrp(child.child_fd)  # an ioctl on kitty's own pty
            except (OSError, TypeError):
                pgid = -1
            reported = w.screen.last_reported_cwd
            panes.append({"pid": child.pid, "pgid": pgid,
                          "osc7": path_from_osc7_url(reported) if reported else ""})
        self.send({"op": "panes", "panes": panes}, self._on_panes)

    def poll(self, _timer_id=None):
        self._panes_arrived = False
        for _ in range(MAX_REPLIES_PER_TICK):
            reply = self.service.try_recv()
            if reply is None:
                break
            callback = self.pending.pop(reply.request_id, None)
            if callback is None or reply.payload is None:
                continue  # fire-and-forget ack, or the connection dropped
            try:
                callback(json.loads(reply.payload))
            except Exception:
                pass
        if self._panes_arrived:
            for f in list(self.listeners):
                try:
                    f()
                except Exception:
                    pass

    @contextmanager
    def offline(self):
        """Answer kitty.child's /proc lookups from the worker's last reply.

        kitty reaches /proc only through these kitty.child functions, so for
        the duration nothing kitty does on our behalf can block. A group is
        assumed to hold just its leader (pid == pgid), which is what the
        worker resolved; unknown pids raise, and kitty falls back to what it
        already holds in memory (argv, the launch cwd).
        """
        import kitty.child as kc
        procs = self.procs

        def field(pid, key):
            info = procs.get(pid)
            if info is None or not info.get(key):
                raise OSError(f"kitty-worker has no {key} for {pid}")
            return info[key]

        class LeaderMap(dict):
            def __missing__(self, pgid):
                return [pgid] if pgid in procs else []

        swap = {
            "cmdline_of_pid": lambda pid: field(pid, "cmdline"),
            "cwd_of_process": lambda pid: field(pid, "cwd"),
            "abspath_of_exe": lambda pid: field(pid, "exe"),
            "environ_of_process": lambda pid: field(pid, "environ"),
            "process_group_map": LeaderMap,
            "processes_in_group": lambda pgid: [pgid] if pgid in procs else [],
        }
        saved = {k: getattr(kc, k) for k in swap if hasattr(kc, k)}
        for k in saved:
            setattr(kc, k, swap[k])
        try:
            yield
        finally:
            for k, v in saved.items():
                setattr(kc, k, v)


def get():
    from kitty.boss import get_boss
    return getattr(get_boss(), "kitty_worker", None)


def install():
    from kitty.boss import get_boss
    from kitty.fast_data_types import add_timer, remove_timer
    boss = get_boss()
    if boss is None:
        return None
    old = getattr(boss, "kitty_worker", None)
    for name in ("kitty_worker_poll_timer", "kitty_worker_panes_timer"):
        if (t := getattr(boss, name, None)) is not None:
            remove_timer(t)
    # Keep the live connection across a reload (an older Client, from before
    # the move to running-process, has none and is replaced).
    service = getattr(old, "service", None)
    client = Client(boss, service)
    if old is not None:
        # Keep what is known across a reload; listeners re-register themselves.
        client.procs, client.branches, client.files = old.procs, old.branches, old.files
        if service is not None:
            client.pending = old.pending
        elif hasattr(old, "close"):
            old.close()
    boss.kitty_worker = client
    boss.kitty_worker_poll_timer = add_timer(client.poll, POLL_INTERVAL, True)
    boss.kitty_worker_panes_timer = add_timer(client.request_panes, PANES_INTERVAL, True)
    client.request_panes()
    return client
