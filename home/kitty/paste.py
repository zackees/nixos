#!/usr/bin/env python3
"""Smart clipboard paste; --confirm previews the payload type and byte size.

If the clipboard holds an image, save it and paste the file's path (a
terminal cannot receive image bytes, but a path is what you actually want).
Otherwise paste the clipboard text as normal.
"""
import os
import shlex
import subprocess
import tempfile

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


def _clipboard_image():
    """Read image bytes once, without saving a file before confirmation."""
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
            result = subprocess.run(
                [_wl_paste(), '--type', mime], capture_output=True, timeout=10,
            )
            if result.returncode == 0 and result.stdout:
                return result.stdout, ext
        except Exception:
            pass
    return None


def _read_clipboard():
    image = _clipboard_image()
    if image:
        data, ext = image
        return 'image', data, ext
    from kitty.clipboard import get_clipboard_string
    return 'text', get_clipboard_string(), ''


def _save_image(data, ext):
    os.makedirs(SAVE_DIR, exist_ok=True)
    # Rapid pastes must never overwrite an image pasted earlier.
    with tempfile.NamedTemporaryFile(
        dir=SAVE_DIR, prefix='paste-', suffix='.' + ext, delete=False,
    ) as output:
        try:
            output.write(data)
            output.flush()
        except OSError:
            os.unlink(output.name)
            raise
    return output.name


def _prompt(payload):
    kind, data, _ = payload
    size = len(data.encode('utf-8')) if kind == 'text' else len(data)
    # Decimal kB, rounded up so a nonempty clipboard never says 0kB.
    return f'Paste {kind} ({(size + 999) // 1000}kB) [y/n]'


def main(args):
    raise SystemExit('This kitten must be used only from a kitty.conf mapping')


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    w = boss.window_id_map.get(target_window_id)
    if w is None:
        return
    if '--confirm' in args[1:]:
        payload = _read_clipboard()

        def confirmed(accepted):
            # Do not redirect to a newly focused pane while the prompt is open.
            # Paste exactly the snapshot described, even if clipboard changes.
            if accepted:
                paste_into(target_window_id, boss, payload)

        boss.confirm(_prompt(payload), confirmed, window=w,
                     confirm_on_accept=False, confirm_on_cancel=False,
                     title='Paste clipboard')
        return
    paste_into(target_window_id, boss)


def paste_into(target_window_id, boss, payload=None):
    w = boss.window_id_map.get(target_window_id)
    if w is None:
        return
    kind, data, ext = payload if payload is not None else _read_clipboard()
    if kind == 'image':
        try:
            path = _save_image(data, ext)
        except OSError as error:
            boss.show_error('Paste failed', f'Could not save clipboard image: {error}')
            return
        # paste_text applies bracketed paste and the configured paste_actions
        w.paste_text(shlex.quote(path))
        return
    if data:
        w.paste_text(data)
