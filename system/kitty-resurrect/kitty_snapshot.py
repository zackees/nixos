"""Save every kitty OS window as a session, so a crash does not lose them.

Loaded by tab_bar.py, including on SIGUSR1, so existing terminals participate.
Kitty's own serialize_state_as_session does the real work -- tabs, layouts,
split geometry, working directories -- one OS window at a time, so the
resurrect service can put each one back on its own screen and desktop.

The file lives in XDG_STATE_HOME, not the runtime dir: it has to survive a
reboot as well as a compositor crash.

All of this runs on kitty's main thread, which draws every terminal, so
nothing here touches /proc or the disk: kitty-worker (system/kitty-worker)
answers the process lookups and does every read and write.
"""
import json
import os
import re
from pathlib import Path
import shlex
import time

INTERVAL = 5.0
FOCUS_INTERVAL = 0.5
UNSERIALIZE = "kitty-unserialize-data="


def continue_agent(command):
    """An agent re-run verbatim starts a fresh conversation; continue instead.

    kitty stores the command as a string when it came from shell integration
    and as an argv list otherwise; the answer keeps whichever form it got.
    """
    if isinstance(command, list):
        words = [str(w) for w in command]
    else:
        try:
            words = shlex.split(command)
        except ValueError:
            return command
    if not words:
        return command
    name = os.path.basename(words[0])
    if name == "clud":
        # `-c 0` picks the newest session in this directory straight away;
        # bare -c opens a picker, which a restore cannot answer. The harness
        # flag stays, so a codex pane continues a codex session.
        harness = [w for w in words[1:] if w in ("--codex", "--gemini", "--opencode", "--claude")]
        words = [words[0]] + harness + ["-c", "0"]
    elif name == "claude":
        words = [words[0], "--continue"]
    elif name == "codex":
        words = [words[0], "resume", "--last"]
    else:
        return command
    return words if isinstance(command, list) else shlex.join(words)


# One shell word, quoted or not; and the pieces inside one. Both are C regex
# scans, where shlex walks the line a character at a time in Python.
WORD = re.compile(r"""(?:'[^']*'|"(?:\\.|[^"\\])*"|\\.|[^\s'"\\])+""")
PIECE = re.compile(r"""'([^']*)'|"((?:\\.|[^"\\])*)"|\\(.)|([^'"\\]+)""")


def unquote(word):
    return "".join(a or (re.sub(r"\\(.)", r"\1", b) if b else c or d or "")
                   for a, b, c, d in PIECE.findall(word))


def continue_agents(lines):
    # Only the unserialize word is touched. shlex.split over the whole line --
    # which carries kitty's per-pane JSON, ~20 KB -- cost 82 ms of kitty's
    # main thread per snapshot on an idle machine and 80-91 ms stalls every
    # 5 s (perf + py-spy, 2026-10-26).
    out = []
    for line in lines:
        at = line.find(UNSERIALIZE) if line.startswith("launch ") else -1
        if at >= 0 and "cmd_at_shell_startup" in line:
            try:
                begin = line.rfind(" ", 0, at) + 1
                m = WORD.match(line, begin)
                word = unquote(m.group(0))
                data = json.loads(word[len(UNSERIALIZE):])
                if data.get("cmd_at_shell_startup"):
                    data["cmd_at_shell_startup"] = continue_agent(data["cmd_at_shell_startup"])
                    line = (line[:begin] + shlex.quote(UNSERIALIZE + json.dumps(data))
                            + line[m.end():])
            except Exception:
                pass  # An unrecognised line is saved as kitty wrote it.
        out.append(line)
    return out


def install():
    from kitty.boss import get_boss
    from kitty.fast_data_types import (add_timer, current_focused_os_window_id,
                                       get_os_window_title, remove_timer,
                                       set_os_window_title)
    from kitty.session import parse_save_as_options_spec_args

    boss = get_boss()
    for name in ("resurrect_timer", "resurrect_focus_timer"):
        old = getattr(boss, name, None)
        if old is not None:
            remove_timer(old)

    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    pid = os.getpid()
    path = Path(base) / "kitty-resurrect" / f"kitty-{pid}.json"
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    focus_path = Path(runtime) / f"kitty-resurrect-focus-{pid}" if runtime else None
    # With shell integration this records what each shell is running, so a
    # pane sitting in clud comes back in clud (see continue_agents).
    opts = parse_save_as_options_spec_args(["--use-foreground-process", "--save-only"])[0]
    last = {"windows": None, "focus": None}

    def snapshot(_timer_id):
        try:
            windows = []
            worker = getattr(boss, "kitty_worker", None)
            if worker is None:
                return
            # Each pane's foreground process comes from kitty-worker's last
            # reply. Left to itself kitty scans all of /proc per pane -- ~1.3 s
            # of this thread per snapshot under a build (py-spy, 2026-10-25).
            with worker.offline():
                serialized = [(os_id, manager, manager.serialize_state_as_session(
                    str(path), None, opts, is_first=True))
                    for os_id, manager in list(boss.os_window_map.items())]
            for os_id, manager, lines in serialized:
                if not lines:
                    continue
                active = manager.active_window
                title = get_os_window_title(os_id) or (active.title if active else "")
                windows.append(dict(id=os_id, title=title,
                                    session="\n".join(continue_agents(lines)) + "\n"))
            # An empty map is kitty shutting down, not the state to restore.
            if not windows or windows == last["windows"]:
                return
            last["windows"] = windows
            worker.write(path, json.dumps(dict(pid=pid, time=time.time(), windows=windows)))
        except Exception:
            pass  # Saving state must never stop the terminal from drawing.

    def unpin():
        # A restore marks each OS window's first pane with a unique tag
        # (--var=kitty_resurrect=TAG). Shown as the OS window's title, it is
        # what lets KWin tell otherwise identical windows apart and give each
        # its own place. Once placed, the service lists the tag in the unpin
        # file and the title goes back to following the shell. Not a session
        # `os_window_title`: kitty pins that one for the window's lifetime.
        worker = getattr(boss, "kitty_worker", None)
        if worker is None or not runtime:
            return
        unpin_path = str(Path(runtime) / "kitty-resurrect-unpin")
        worker.read(unpin_path)  # the answer is used on the next tick
        placed = set((worker.files.get(unpin_path) or "").split())
        try:
            for os_id, manager in list(boss.os_window_map.items()):
                for tab in manager.tabs:
                    for w in tab.windows:
                        tag = w.user_vars.get("kitty_resurrect")
                        if not tag:
                            continue
                        if tag in placed:
                            del w.user_vars["kitty_resurrect"]
                            set_os_window_title(os_id, "")
                        elif get_os_window_title(os_id) != tag:
                            set_os_window_title(os_id, tag)
        except Exception:
            pass

    def focus(_timer_id):
        # The service pairs this with KWin's active window to learn which
        # KWin window is which OS window; titles alone are ambiguous.
        unpin()
        try:
            focused = current_focused_os_window_id()
            if focus_path and focused > 0 and focused != last["focus"]:
                last["focus"] = focused
                worker = getattr(boss, "kitty_worker", None)
                if worker is not None:
                    worker.write(focus_path, str(focused))
        except Exception:
            pass

    boss.resurrect_timer = add_timer(snapshot, INTERVAL, True)
    boss.resurrect_focus_timer = add_timer(focus, FOCUS_INTERVAL, True)
    snapshot(None)
