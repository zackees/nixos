# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Claude Code Notification hook: say WHICH session wants you, and why.

Claude Code's own terminal notification is a fixed "Claude is waiting for
your input", the same for every session, so with several agents open it
cannot tell you where to look. This hook gets the session's cwd and
transcript on stdin and sends kitty a notification titled with the repo
(and branch), carrying the notification's own message plus the tail of
Claude's last reply.

It is delivered as kitty's OSC 99 escape written to the session's terminal,
not through notify-send, so clicking it focuses that kitty window just as
the built-in one did. The hook has no controlling terminal of its own; the
terminal is found by walking up to the first ancestor (the claude process)
whose stdout is a /dev/pts device.
"""

import base64
import json
import os
import subprocess
import sys

SNIPPET_MAX = 180


def _git(cwd: str, *args: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=2
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def where(cwd: str) -> str:
    """`nixos (main)`, `zachvorhies_com (fix/x) · src`, or the folder name."""
    top = _git(cwd, "rev-parse", "--show-toplevel")
    if not top:
        return os.path.basename(cwd.rstrip("/")) or cwd or "?"
    label = os.path.basename(top)
    branch = _git(cwd, "branch", "--show-current")
    if branch:
        label += f" ({branch})"
    rel = os.path.relpath(cwd, top)
    return label if rel == "." else f"{label} · {rel}"


def _text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and part.get("type") == "text"
        )
    return ""


def last_reply(transcript: str) -> str:
    """The end of Claude's most recent text reply, one line, trimmed."""
    try:
        with open(transcript, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 512 * 1024))
            lines = handle.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        message = entry.get("message") if isinstance(entry, dict) else None
        if entry.get("type") != "assistant" or not isinstance(message, dict):
            continue
        text = " ".join(_text(message.get("content")).split())
        if text:
            if len(text) > SNIPPET_MAX:
                text = "…" + text[-(SNIPPET_MAX - 1) :].lstrip()
            return text
    return ""


def session_tty() -> str | None:
    pid = os.getppid()
    for _ in range(12):
        try:
            target = os.readlink(f"/proc/{pid}/fd/1")
        except OSError:
            target = ""
        if target.startswith("/dev/pts/"):
            return target
        try:
            with open(f"/proc/{pid}/stat") as stat:
                pid = int(stat.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            return None
        if pid <= 1:
            return None
    return None


def osc99(title: str, body: str, ident: str) -> bytes:
    def part(meta: str, text: str) -> str:
        payload = base64.b64encode(text.encode()).decode()
        return f"\x1b]99;i={ident}:{meta}:e=1;{payload}\x1b\\"

    return (part("d=0:p=title", title) + part("d=1:p=body", body)).encode()


def _log(kind: str, title: str, tty: str | None) -> None:
    """One line per popup, so a silent hook can be told from a missing one."""
    path = os.path.expanduser("~/.local/state/claude-notify.log")
    try:
        if os.path.getsize(path) > 256 * 1024:
            os.replace(path, path + ".1")
    except OSError:
        pass
    try:
        from datetime import datetime

        with open(path, "a") as log:
            log.write(f"{datetime.now():%F %T} {kind or '-'} {tty or 'no-tty'} {title}\n")
    except OSError:
        pass


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    cwd = event.get("cwd") or os.getcwd()
    title = f"Claude · {where(cwd)}"
    message = event.get("message") or "Claude is waiting for your input"
    snippet = last_reply(event.get("transcript_path") or "")
    body = f"{message}\n{snippet}" if snippet else message
    tty = session_tty()
    _log(event.get("notification_type") or "", title, tty)
    if tty is None:
        return 0  # Nowhere to draw it; never fail the session over a popup.
    ident = (event.get("session_id") or "claude")[:16].replace(":", "")
    try:
        fd = os.open(tty, os.O_WRONLY | os.O_NOCTTY)
        try:
            os.write(fd, osc99(title, body, ident))
        finally:
            os.close(fd)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
