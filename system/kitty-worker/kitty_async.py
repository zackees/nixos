"""kitty's half of kitty-worker: ask, never wait.

Runs on kitty's main thread, which draws every terminal, so it must not
block: no file or /proc access after install, only non-blocking datagrams to
kitty-worker (worker.py) and in-memory reads of the last reply. A dead or
slow worker costs stale labels, never a frozen terminal.

    client = get()            # the one Client, kept on kitty's boss
    with client.offline():    # kitty's /proc lookups answered from the cache
        exe = window.get_exe_of_child()
    client.branch(wd)         # '' until the worker has answered
    client.write(path, text)  # atomic write, done by the worker
    client.read(path)         # ask; client.files[path] holds the answer later
    client.request(msg, f)    # f(reply) runs on kitty's thread when it arrives
    client.listeners.append(f)  # called after each reply

Loaded by tab_bar.py, including on SIGUSR1; install() replaces the timers.
"""

import json
import os
import socket
from contextlib import contextmanager

PANES_INTERVAL = 0.5
POLL_INTERVAL = 0.05


class Client:
    def __init__(self, boss):
        self.boss = boss
        self.procs = {}       # pid -> {cmdline, cwd, exe}, from the last reply
        self.branches = {}    # dir -> branch
        self.files = {}       # path -> text (None: missing), from read()
        self.listeners = []
        self.pending = {}     # request id -> callback
        self.next_id = 1
        runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
        self.server = os.path.join(runtime, "kitty-worker.sock")
        self.address = os.path.join(runtime, f"kitty-worker-client-{os.getpid()}.sock")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
        try:
            os.unlink(self.address)  # io-ok: once at install, tmpfs
        except OSError:
            pass
        self.sock.bind(self.address)

    def close(self):
        self.sock.close()

    def send(self, msg):
        try:
            self.sock.sendto(json.dumps(msg).encode(), self.server)
        except OSError:
            pass  # worker down or its queue full: drop, the next tick resends

    def write(self, path, text):
        self.send({"op": "write", "path": str(path), "text": text})

    def delete(self, path):
        self.send({"op": "unlink", "path": str(path)})

    def request(self, msg, callback):
        msg = dict(msg, id=self.next_id)
        self.pending[self.next_id] = callback
        self.next_id += 1
        if len(self.pending) > 64:  # replies that will never come
            self.pending.pop(min(self.pending))
        self.send(msg)

    def read(self, path):
        self.send({"op": "read", "path": str(path)})

    def branch(self, wd):
        return self.branches.get(wd, "")

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
        self.send({"op": "panes", "panes": panes})

    def poll(self, _timer_id=None):
        got = False
        while True:
            try:
                data = self.sock.recv(4 << 20)
            except (BlockingIOError, OSError):
                break
            try:
                msg = json.loads(data)
            except ValueError:
                continue
            if (callback := self.pending.pop(msg.get("id"), None)) is not None:
                try:
                    callback(msg)
                except Exception:
                    pass
            elif msg.get("op") == "panes":
                self.procs = {int(k): v for k, v in msg.get("procs", {}).items()}
                self.branches.update(msg.get("branches", {}))
                if len(self.branches) > 256:
                    self.branches = dict(msg.get("branches", {}))
                got = True
            elif msg.get("op") == "read":
                self.files[msg.get("path")] = msg.get("text")
        if got:
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
    client = Client(boss)
    if old is not None:
        # Keep what is known across a reload; listeners re-register themselves.
        client.procs, client.branches, client.files = old.procs, old.branches, old.files
        client.pending, client.next_id = old.pending, old.next_id
        old.close()
    boss.kitty_worker = client
    boss.kitty_worker_poll_timer = add_timer(client.poll, POLL_INTERVAL, True)
    boss.kitty_worker_panes_timer = add_timer(client.request_panes, PANES_INTERVAL, True)
    client.request_panes()
    return client
