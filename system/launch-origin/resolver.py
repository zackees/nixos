"""Resolve local process ancestry to an existing window, without focus guesses."""
import json
from pathlib import Path
import time


class Resolver:
    def __init__(self, proc=Path("/proc"), runtime=None):
        self.proc = Path(proc)
        self.runtime = Path(runtime)

    def process(self, pid):
        try:
            # comm is parenthesized and can itself contain spaces or ')'.
            fields = (self.proc / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
            return int(fields[1]), fields[19]
        except (OSError, ValueError, IndexError):
            return None

    def kitty_hint(self, pid):
        try:
            raw = (self.proc / str(pid) / "environ").read_bytes()
            # Never retain, log, or serialize the rest of the environment.
            selected = {}
            for entry in raw.split(b"\0"):
                key, _, value = entry.partition(b"=")
                if key in (b"KITTY_PID", b"KITTY_WINDOW_ID"):
                    selected[key] = int(value)
            return selected[b"KITTY_PID"], selected[b"KITTY_WINDOW_ID"]
        except (OSError, ValueError, KeyError):
            return None

    def kitty_window(self, hint, windows):
        if not hint:
            return ""
        pid, pane = hint
        process = self.process(pid)
        if not process:
            return ""
        try:
            path = self.runtime / f"kitty-launch-origin-{pid}.json"
            data = json.loads(path.read_text())
            age = time.monotonic() - data["time"]
            if data["start"] != process[1] or not 0 <= age <= 3:
                return ""
            owners = [w for w in data["windows"] if pane in w["panes"]]
            if len(owners) != 1:
                return ""
            title = owners[0]["title"]
            if not title or sum(w["title"] == title for w in data["windows"]) != 1:
                return ""
            # The script supplies captionNormal, without KWin's duplicate
            # caption suffix. Identical terminal titles remain ambiguous.
            candidates = [w for w in windows if w["pid"] == pid and
                          w["caption"] == title]
            return candidates[0]["id"] if len(candidates) == 1 else ""
        except (OSError, ValueError, KeyError, TypeError):
            return ""

    def resolve(self, pid, windows):
        if pid <= 1 or not self.process(pid):
            return ""
        original = pid
        seen = set()
        for _ in range(64):
            if pid <= 1 or pid in seen:
                break
            seen.add(pid)
            process = self.process(pid)
            if not process:
                break
            parent = process[0]
            candidates = [w for w in windows if w["pid"] == parent]
            if len(candidates) == 1:
                return candidates[0]["id"]
            if candidates:
                hint = self.kitty_hint(pid)
                return self.kitty_window(hint, candidates) if hint and hint[0] == parent else ""
            pid = parent
        # A daemonized descendant may have lost its parent but retained the
        # pane identity. Existing single-instance windows are never matched
        # to their own PID, so unrelated sibling windows cannot become parents.
        hint = self.kitty_hint(original)
        if hint and hint[0] != original:
            return self.kitty_window(hint, windows)
        return ""
