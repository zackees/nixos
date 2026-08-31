#!/usr/bin/env python3
"""Smart paste for kitty, bound to super+v.

If the clipboard holds an image, save it and paste the file's path (a
terminal cannot receive image bytes, but a path is what you actually want).
Otherwise paste the clipboard text as normal.
"""
import os
import shlex
import subprocess
import time

from kittens.tui.handler import result_handler

WL_PASTE = '/run/current-system/sw/bin/wl-paste'
SAVE_DIR = os.path.expanduser('~/Pictures/kitty-pastes')
IMAGE_TYPES = (
    ('image/png', 'png'),
    ('image/jpeg', 'jpg'),
    ('image/webp', 'webp'),
    ('image/gif', 'gif'),
)


def _wl_paste():
    return WL_PASTE if os.access(WL_PASTE, os.X_OK) else 'wl-paste'


def _clipboard_image_path():
    """Save a clipboard image to disk, returning its path, else None."""
    try:
        types = subprocess.run(
            [_wl_paste(), '--list-types'],
            capture_output=True, text=True, timeout=2,
        ).stdout.split()
    except Exception:
        return None

    for mime, ext in IMAGE_TYPES:
        if mime not in types:
            continue
        try:
            os.makedirs(SAVE_DIR, exist_ok=True)
            path = os.path.join(
                SAVE_DIR, time.strftime('paste-%Y%m%d-%H%M%S.') + ext)
            with open(path, 'wb') as f:
                rc = subprocess.run(
                    [_wl_paste(), '--type', mime], stdout=f, timeout=10,
                ).returncode
            if rc == 0 and os.path.getsize(path) > 0:
                return path
            os.unlink(path)
        except Exception:
            pass
    return None


def main(args):
    raise SystemExit('This kitten must be used only from a kitty.conf mapping')


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    w = boss.window_id_map.get(target_window_id)
    if w is None:
        return
    path = _clipboard_image_path()
    if path:
        # paste_text applies bracketed paste and the configured paste_actions
        w.paste_text(shlex.quote(path))
        return
    from kitty.clipboard import get_clipboard_string
    text = get_clipboard_string()
    if text:
        w.paste_text(text)
