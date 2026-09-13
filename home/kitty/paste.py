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

# The declaratively provisioned user Python includes Tk. Run its GUI outside
# Kitty's event loop; Kitty's own confirmation is a full-pane overlay.
POPUP_PYTHON = os.path.expanduser('~/.venv/bin/python')
POPUP_CODE = '''
import sys
import tkinter as tk
from tkinter import ttk

root = tk.Tk()
root.withdraw()
root.title('Paste clipboard')
root.resizable(False, False)
root.attributes('-topmost', True)
root.attributes('-type', 'dialog')
accepted = False

def finish(value=False):
    global accepted
    accepted = value
    root.destroy()

frame = ttk.Frame(root, padding=18)
frame.pack()
ttk.Label(frame, text=sys.argv[1]).pack(pady=(0, 14))
buttons = ttk.Frame(frame)
buttons.pack()
ttk.Button(buttons, text='Yes (Y)', command=lambda: finish(True)).pack(side='left', padx=6)
no = ttk.Button(buttons, text='No (N)', command=finish)
no.pack(side='left', padx=6)
for key in ('y', 'Y'):
    root.bind('<Key-' + key + '>', lambda event: finish(True))
for key in ('n', 'N', 'Escape', 'Return'):
    root.bind('<Key-' + key + '>', lambda event: finish(False))
root.protocol('WM_DELETE_WINDOW', finish)
root.update_idletasks()
x = max(0, min(root.winfo_pointerx() + 12, root.winfo_screenwidth() - root.winfo_reqwidth()))
y = max(0, min(root.winfo_pointery() + 12, root.winfo_screenheight() - root.winfo_reqheight()))
root.geometry(f'+{x}+{y}')
root.deiconify()
no.focus_set()
root.after(120000, finish)
root.mainloop()
sys.exit(0 if accepted else 1)
'''


def _confirm_popup(boss, message, callback):
    def finished(status, error):
        # Cancellation, a crash, and launch failure all fail closed.
        if error is not None:
            boss.show_error('Paste confirmation unavailable', str(error))
        callback(error is None and status == 0)

    boss.run_background_process(
        [POPUP_PYTHON, '-c', POPUP_CODE, message], notify_on_death=finished)


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

        _confirm_popup(boss, _prompt(payload), confirmed)
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
