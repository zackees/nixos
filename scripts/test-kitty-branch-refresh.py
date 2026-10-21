"""Exercise an idle Kitty caption on a private Xvfb display.

Pass an existing empty --workdir; --renderer can select the old implementation
to reproduce the failure. No keyboard input or user checkout is touched.
"""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workdir', type=Path, required=True)
    parser.add_argument('--renderer', type=Path)
    args = parser.parse_args()
    root = args.workdir.resolve()
    repo = Path(__file__).resolve().parents[1]
    config = root / 'config'
    config.mkdir()
    runtime = root / 'runtime'
    runtime.mkdir(mode=0o700)
    checkout = root / 'checkout'
    checkout.mkdir()
    run('git', 'init', '--initial-branch=before', str(checkout))
    run('git', '-C', str(checkout), '-c', 'user.name=Header Test', '-c', 'user.email=header@test.invalid',
        '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '--allow-empty', '-m', 'fixture')
    run('git', '-C', str(checkout), 'branch', 'main')
    shutil.copy2(repo / 'home/kitty/tab_bar.py', config / 'tab_bar.py')
    renderer = (args.renderer or repo / 'home/kitty/window_title_bar.py').resolve()
    fifo = root / 'captions.fifo'
    os.mkfifo(fifo)
    reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    keeper = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    # Observe exactly what the real Kitty renderer returns. The original
    # timer and title drawing remain intact; the observer never blocks the UI.
    (config / 'window_title_bar.py').write_text(f'''
import runpy
globals().update(runpy.run_path({str(renderer)!r}))
import json
from kitty.fast_data_types import add_timer
_original_draw = draw_window_title
def draw_window_title(data):
    label = _original_draw(data)
    def after_paint(_timer_id):
        fd = os.open({str(fifo)!r}, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, (json.dumps(label) + '\\n').encode())
        finally:
            os.close(fd)
    # Let Kitty complete its render and repaint before taking a screenshot.
    add_timer(after_paint, 0.1, False)
    return label
''')
    (config / 'kitty.conf').write_text('''
linux_display_server x11
window_title_bar top
window_title_bar_align left
window_title_bar_min_windows 1
window_title_bar_active_background #2a2e32
window_title_bar_active_foreground #3daee9
window_title_template "{custom}"
tab_bar_style custom
tab_bar_min_tabs 2
confirm_os_window_close 0
shell_integration disabled
font_size 14
''')
    ready, writer = os.pipe()
    log = (root / 'kitty.log').open('wb')
    xvfb = subprocess.Popen(['Xvfb', '-displayfd', str(writer), '-screen', '0', '1000x320x24',
                             '-nolisten', 'tcp'], pass_fds=(writer,), stdout=log, stderr=log)
    os.close(writer)
    kitty = None
    buffer = b''

    def caption(branch):
        nonlocal buffer
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if not select.select([reader], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            buffer += os.read(reader, 65536)
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                value = json.loads(line)
                if f' {branch}' in value:
                    return value
        raise AssertionError(f'Header did not update to {branch!r} with its application title unchanged')

    try:
        if not select.select([ready], [], [], 5)[0]:
            raise RuntimeError('private Xvfb did not start')
        display = ':' + os.read(ready, 100).decode().strip()
        env = {**os.environ, 'DISPLAY': display, 'XDG_RUNTIME_DIR': str(runtime),
               'KITTY_CONFIG_DIRECTORY': str(config)}
        kitty = subprocess.Popen(['kitty', '--title', 'constant-agent-title', '--directory', str(checkout),
                                  sys.executable, '-c', 'import signal; signal.pause()'],
                                 env=env, stdout=log, stderr=log)
        print('Initial caption:', caption('before'))
        run('magick', 'import', '-display', display, '-window', 'root', str(root / 'before.png'))
        run('git', '-C', str(checkout), 'switch', 'main')
        print('Updated caption:', caption('main'))
        run('magick', 'import', '-display', display, '-window', 'root', str(root / 'after.png'))
        print('PASS: real Kitty header followed an external branch switch without title, focus or input changes')
    finally:
        if kitty is not None and kitty.poll() is None:
            kitty.terminate()
            kitty.wait(timeout=10)
        xvfb.terminate()
        xvfb.wait(timeout=10)
        os.close(reader)
        os.close(keeper)
        os.close(ready)
        log.close()


if __name__ == '__main__':
    main()
