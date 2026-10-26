# /// script
# requires-python = ">=3.12"
# dependencies = ["running-process==4.10.17"]
# ///
"""kitty-worker: does kitty's blocking work so kitty's main thread never does.

Everything our code runs inside kitty runs on kitty's main thread, the one
that draws every terminal. A /proc read that waits on a busy process's
memory map, or a file write queued behind the ext4 journal, freezes every
terminal for as long as it takes (2026-10-25: up to 1.3 s every 5 s). So
kitty-side code only sends requests here and reads replies on a later tick;
see kitty_async.py for that half.

Transport: running-process's supervised service (running_process_service),
service "kitty-worker" on private-use payload protocol 0xF0B7. It owns the
single-instance endpoint, the identity file kitty's client health-probes, and
request-id matching. Every request gets a reply; for write/unlink it is {}.

Protocol: one JSON object per request.
  {"op": "panes", "panes": [{"pid": shell, "pgid": foreground group,
                             "osc7": dir or ""}]}
      -> {"op": "panes", "procs": {pid: {cmdline, cwd, exe}},
          "branches": {dir: branch}, "remotes": {dir: https url or ""}}
  {"op": "read", "path": p}  -> {"op": "read", "path": p, "text": t or null}
  {"op": "write", "path": p, "text": t}     atomic write, no reply
  {"op": "unlink", "path": p}                no reply
  {"op": "clip", "id": n}  -> {"id": n, "kind": "image", "path": saved, "size": bytes}
                              | {"id": n, "kind": "text"} | {"id": n, "error": e}
      An image on the clipboard is read with wl-paste, PNG re-encoded as
      quality-95 JPEG (Klipper's own JPEG is quality 75) and saved under
      ~/Pictures/kitty-pastes; kitty pastes the path. Text stays in kitty.
Reads and writes are confined to kitty's state and runtime directories.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

from running_process_service import ServiceSpec, serve

RUNTIME = os.environ["XDG_RUNTIME_DIR"]
STATE = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
PASTES = os.path.expanduser("~/Pictures/kitty-pastes")
WRITABLE = (os.path.join(STATE, "kitty-resurrect") + os.sep, RUNTIME + os.sep, PASTES + os.sep)
IMAGE_TYPES = (("image/png", "png"), ("image/jpeg", "jpg"), ("image/webp", "webp"),
               ("image/gif", "gif"))
BRANCH_MAX = 22
SPEC = ServiceSpec(name="kitty-worker", version="2", payload_protocol=0xF0B7)


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


def remote(wd):
    """origin's web URL for the repo governing `wd`, or ''.

    git@host:o/r.git and ssh://git@host/o/r become https://host/o/r. A
    worktree's .git file points at <main>/.git/worktrees/<name>; its config
    is the main repo's, two levels up.
    """
    head = git_head(wd)
    if head is None:
        return ""
    gitdir = os.path.dirname(head)
    if os.path.basename(os.path.dirname(gitdir)) == "worktrees":
        gitdir = os.path.dirname(os.path.dirname(gitdir))
    url, section = "", ""
    try:
        with open(os.path.join(gitdir, "config"), encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("["):
                    section = line
                elif section == '[remote "origin"]' and line.startswith("url"):
                    url = line.partition("=")[2].strip()
                    break
    except OSError:
        return ""
    m = re.match(r"(?:ssh://)?[^@/]+@([^:/]+)[:/](.+)", url) or re.match(r"https?://(?:[^@/]+@)?([^/]+)/(.+)", url)
    if not m:
        return ""
    path = m.group(2)
    path = path[:-4] if path.endswith(".git") else path
    return f"https://{m.group(1)}/{path.strip('/')}"


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
    return {"op": "panes", "procs": procs, "branches": {d: branch(d) for d in dirs},
            "remotes": {d: remote(d) for d in dirs}}


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


def handle(payload):
    try:
        msg = json.loads(payload)
        op = msg.get("op")
        if op in ("write", "unlink"):
            write(msg)
            return b"{}"
        reply = {"panes": panes, "read": read, "clip": clip}.get(op)
        if reply is None:
            return json.dumps({"op": op, "error": "unknown op"}).encode()
        try:
            out = reply(msg)
        except (OSError, subprocess.SubprocessError) as e:
            out = {"op": op, "error": str(e)}
        return json.dumps(out).encode()
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        print(f"kitty-worker: {type(e).__name__}: {e}", file=sys.stderr)
        return json.dumps({"error": f"{type(e).__name__}: {e}"}).encode()


def main():
    # Worker threads, so one /proc read stuck on a busy process delays
    # nothing else; replies go back out of order, matched by request id.
    serve(SPEC, handle, workers=4)


if __name__ == "__main__":
    main()
