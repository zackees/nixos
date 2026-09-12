"""Publish only titles and pane IDs; this does not enable kitty remote control.

Loaded by tab_bar.py, including on SIGUSR1, so existing terminals participate.
Kitty's main-loop timer keeps all access to its window objects on its UI thread.
"""
import json
import os
from pathlib import Path
import tempfile
import time


def install():
    from kitty.boss import get_boss
    from kitty.fast_data_types import add_timer, get_os_window_title, remove_timer

    boss = get_boss()
    old_timer = getattr(boss, "launch_origin_timer", None)
    if old_timer is not None:
        remove_timer(old_timer)
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        return
    pid = os.getpid()
    start = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    path = Path(runtime) / f"kitty-launch-origin-{pid}.json"

    def publish(_timer_id):
        temporary = None
        try:
            windows = []
            for os_id, manager in boss.os_window_map.items():
                panes = [w.id for tab in manager.tabs for w in tab.windows]
                # A fixed CLI title can bypass kitty's C-side title cache.
                # The active pane provides the normal OS-window title then;
                # a different explicit OS title simply will not match KWin.
                active = manager.active_window
                title = get_os_window_title(os_id) or (active.title if active else "")
                windows.append(dict(title=title, panes=panes))
            with tempfile.NamedTemporaryFile(mode="w", dir=runtime,
                                             prefix=".kitty-launch-origin-", delete=False) as stream:
                temporary = stream.name
                json.dump(dict(start=start, time=time.monotonic(), windows=windows), stream)
            os.replace(temporary, path)
        except Exception:
            # A placement helper must never prevent terminal rendering.
            if temporary:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass

    boss.launch_origin_timer = add_timer(publish, 0.5, True)
    publish(None)
