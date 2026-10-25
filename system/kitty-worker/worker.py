# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""kitty-worker: does kitty's blocking work so kitty's main thread never does.

Everything our code runs inside kitty runs on kitty's main thread, the one
that draws every terminal. A /proc read that waits on a busy process's
memory map, or a file write queued behind the ext4 journal, freezes every
terminal for as long as it takes (2026-10-25: up to 1.3 s every 5 s). So
kitty-side code only sends datagrams here and reads replies later; see
kitty_async.py for that half.

Protocol: one JSON object per datagram on $XDG_RUNTIME_DIR/kitty-worker.sock.
  {"op": "panes", "panes": [{"pid": shell, "pgid": foreground group,
                             "osc7": dir or ""}]}
      -> {"op": "panes", "procs": {pid: {cmdline, cwd, exe}},
          "branches": {dir: branch}}
  {"op": "read", "path": p}  -> {"op": "read", "path": p, "text": t or null}
  {"op": "write", "path": p, "text": t}     atomic write, no reply
  {"op": "unlink", "path": p}                no reply
  {"op": "clip", "id": n}  -> {"id": n, "kind": "image", "path": saved, "size": bytes}
                              | {"id": n, "kind": "text"} | {"id": n, "error": e}
      An image on the clipboard is read with wl-paste, PNG re-encoded as
      quality-95 JPEG (Klipper's own JPEG is quality 75) and saved under
      ~/Pictures/kitty-pastes; kitty pastes the path. Text stays in kitty.
A request carrying "id" gets it back in the reply.
Reads and writes are confined to kitty's state and runtime directories.
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

RUNTIME = os.environ["XDG_RUNTIME_DIR"]
STATE = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
ADDRESS = os.path.join(RUNTIME, "kitty-worker.sock")
PASTES = os.path.expanduser("~/Pictures/kitty-pastes")
WRITABLE = (os.path.join(STATE, "kitty-resurrect") + os.sep, RUNTIME + os.sep, PASTES + os.sep)
IMAGE_TYPES = (("image/png", "png"), ("image/jpeg", "jpg"), ("image/webp", "webp"),
               ("image/gif", "gif"))
BRANCH_MAX = 22
MAX_DATAGRAM = 4 << 20


def proc(pid):
    info = {}
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            info["cmdline"] = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return None
    for key in ("cwd", "exe"):
        try:
            info[key] = os.readlink(f"/proc/{pid}/{key}")
        except OSError:
            info[key] = ""
    return info


def git_head(wd):
    """HEAD governing `wd`; a .git *file* is a worktree or submodule."""
    d = wd
    while True:
        g = os.path.join(d, ".git")
        if os.path.isdir(g):
            return os.path.join(g, "HEAD")
        if os.path.isfile(g):
            try:
                with open(g, encoding="utf-8", errors="replace") as f:
                    line = f.read(4096).strip()
            except OSError:
                return None
            if not line.startswith("gitdir:"):
                return None
            p = line[len("gitdir:"):].strip()
            return os.path.join(p if os.path.isabs(p) else os.path.join(d, p), "HEAD")
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def branch(wd):
    head = git_head(wd)
    if head is None:
        return ""
    try:
        with open(head, encoding="utf-8", errors="replace") as f:
            line = f.read(256).strip()
    except OSError:
        return ""
    if line.startswith("ref: refs/heads/"):
        name = line[len("ref: refs/heads/"):]
    elif line.startswith("ref: "):
        name = line[len("ref: "):]
    else:
        name = line[:7]  # detached: the short sha, as git shows it
    return name if len(name) <= BRANCH_MAX else name[:BRANCH_MAX - 1] + "…"


def panes(msg):
    procs, dirs = {}, set()
    for p in msg.get("panes", []):
        for pid in {p.get("pid"), p.get("pgid")}:
            if isinstance(pid, int) and pid > 0 and str(pid) not in procs:
                if (info := proc(pid)) is not None:
                    procs[str(pid)] = info
                    if info["cwd"]:
                        dirs.add(info["cwd"])
        if p.get("osc7"):
            dirs.add(p["osc7"])
    return {"op": "panes", "procs": procs, "branches": {d: branch(d) for d in dirs}}


def read(msg):
    path = os.path.abspath(msg["path"])
    text = None
    if path.startswith(WRITABLE):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read(1 << 20)
        except OSError:
            pass
    return {"op": "read", "path": msg["path"], "text": text}


def write(msg):
    path = os.path.abspath(msg["path"])
    if not path.startswith(WRITABLE):
        return
    if msg["op"] == "unlink":
        try:
            os.unlink(path)
        except OSError:
            pass
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(msg["text"])
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def clip(msg):
    types = subprocess.run(["wl-paste", "--list-types"], capture_output=True,
                           text=True, timeout=5).stdout.split()
    for mime, ext in IMAGE_TYPES:
        if mime not in types:
            continue
        data = subprocess.run(["wl-paste", "--type", mime], capture_output=True,
                              timeout=20).stdout
        if not data:
            continue
        if ext == "png":
            # Screenshots paste as high-quality JPEG, not resized.
            data = subprocess.run(
                ["magick", "png:-", "-background", "white", "-alpha", "remove",
                 "-alpha", "off", "-sampling-factor", "4:4:4", "-quality", "95", "jpeg:-"],
                input=data, capture_output=True, timeout=30, check=True).stdout
            ext = "jpg"
        os.makedirs(PASTES, exist_ok=True)
        # Unique per paste: rapid pastes never overwrite an earlier image.
        fd, path = tempfile.mkstemp(dir=PASTES, prefix="paste-", suffix="." + ext)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        return {"op": "clip", "kind": "image", "path": path, "size": len(data)}
    return {"op": "clip", "kind": "text"}


def main():
    try:
        os.unlink(ADDRESS)
    except FileNotFoundError:
        pass
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, MAX_DATAGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, MAX_DATAGRAM)
    sock.bind(ADDRESS)
    os.chmod(ADDRESS, 0o600)
    # Threads, so one /proc read stuck on a busy process delays nothing else.
    pool = ThreadPoolExecutor(max_workers=4)

    def handle(data, peer):
        try:
            msg = json.loads(data)
            reply = {"panes": panes, "read": read, "clip": clip}.get(msg.get("op"))
            if reply is not None:
                try:
                    out = reply(msg)
                except (OSError, subprocess.SubprocessError) as e:
                    out = {"op": msg.get("op"), "error": str(e)}
                if "id" in msg:
                    out["id"] = msg["id"]
                if peer:
                    sock.sendto(json.dumps(out).encode(), peer)
            elif msg.get("op") in ("write", "unlink"):
                write(msg)
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"kitty-worker: {type(e).__name__}: {e}", file=sys.stderr)

    while True:
        data, peer = sock.recvfrom(MAX_DATAGRAM)
        pool.submit(handle, data, peer)


if __name__ == "__main__":
    main()
