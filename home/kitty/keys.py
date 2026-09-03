#!/usr/bin/env python3
"""Cheat sheet for kitty, generated from kitty.conf so it can never go stale.

Bound to super+/ in kitty.conf; opens as an overlay over the current pane.
"""
import os
import re
import shutil
import sys

CONF = os.path.join(
    os.environ.get('KITTY_CONFIG_DIRECTORY')
    or os.path.expanduser('~/.config/kitty'),
    'kitty.conf',
)

ACCENT = '\033[38;2;61;174;233m'   # Breeze blue
KEYC = '\033[38;2;253;188;75m'     # amber
DIM = '\033[38;2;127;140;141m'
BOLD = '\033[1m'
OFF = '\033[0m'

DASHES = re.compile(r'^#\s*[\u2500-]{3,}\s*$')
INLINE = re.compile(r'^#\s*[\u2500-]{2,}\s*(.+?)\s*[\u2500-]{2,}\s*$')
COMMENT = re.compile(r'^#\s*(\S.*?)\s*$')

# action -> human phrasing, applied in order
RULES = [
    (r'^launch --location=hsplit', 'Split pane horizontally'),
    (r'^launch --location=vsplit', 'Split pane vertically'),
    (r'^launch --location=split', 'New pane, auto direction'),
    (r'^launch --cwd', 'New pane'),
    (r'^new_window', 'New pane'),
    (r'^neighboring_window (\w+)', 'Focus pane {0}'),
    (r'^move_window (\w+)', 'Move pane {0}'),
    (r'^resize_window reset', 'Reset pane sizes'),
    (r'^resize_window (\w+)', 'Resize pane {0}'),
    (r'^toggle_layout stack', 'Zoom pane in/out'),
    (r'^focus_visible_window', 'Pick a pane visually'),
    (r'^swap_with_window', 'Swap panes visually'),
    (r'^close_window_with_confirmation', 'Close pane'),
    (r'^close_window', 'Close pane'),
    (r'^close_other_windows_in_tab', 'Close all other panes'),
    (r'^detach_window new-tab', 'Tear pane out to its own tab'),
    (r'^detach_window new', 'Tear pane out to its own window'),
    (r'^detach_window', 'Tear pane out (asks where)'),
    (r'^detach_tab', 'Tear tab out to its own window'),
    (r'^goto_layout (\w+)', 'Layout: {0}'),
    (r'^layout_action rotate', 'Rotate the layout'),
    (r'^next_layout', 'Cycle layouts'),
    (r'^new_tab_with_cwd', 'New tab, same directory'),
    (r'^new_tab', 'New tab'),
    (r'^new_os_window_with_cwd', 'New window, same directory'),
    (r'^new_os_window', 'New window'),
    (r'^goto_tab (\d+)', 'Go to tab {0}'),
    (r'^select_tab', 'Choose a tab from a list'),
    (r'^set_tab_title', 'Rename this tab'),
    (r'^show_scrollback', 'Open scrollback in the pager'),
    (r'^show_last_command_output', 'Last command output in the pager'),
    (r'^command_palette', 'Command palette \u2014 every action, searchable'),
    (r'^change_font_size all \+', 'Bigger font'),
    (r'^change_font_size all -', 'Smaller font'),
    (r'^change_font_size all 0', 'Reset font size'),
]


def describe(action):
    for pat, tpl in RULES:
        m = re.match(pat, action)
        if m:
            return tpl.format(*m.groups())
    return None


KEYNAMES = {
    'super': 'Super', 'ctrl': 'Ctrl', 'alt': 'Alt', 'shift': 'Shift',
    'enter': 'Enter', 'minus': '-', 'backslash': '\\', 'slash': '/',
    'plus': 'Plus', 'equal': '=', 'space': 'Space', 'tab': 'Tab',
}


def prettify_key(k):
    out = []
    for p in k.split('+'):
        if p in KEYNAMES:
            out.append(KEYNAMES[p])
        elif re.fullmatch(r'f\d+', p):
            out.append(p.upper())
        elif len(p) == 1:
            out.append(p.upper())
        else:
            out.append(p)
    return '+'.join(out)


def parse():
    try:
        lines = open(CONF, encoding='utf-8').read().splitlines()
    except OSError as e:
        sys.exit('cannot read %s: %s' % (CONF, e))

    order, byname = [], {}
    cur = None
    pending = []

    def section(name):
        if name not in byname:
            byname[name] = []
            order.append(name)
        return byname[name]

    for i, raw in enumerate(lines):
        line = raw.strip()

        if DASHES.match(line):
            # banner form:  #---- / #  Title / #----
            nxt = lines[i + 1].strip() if i + 1 < len(lines) else ''
            nxt2 = lines[i + 2].strip() if i + 2 < len(lines) else ''
            m = COMMENT.match(nxt)
            if m and DASHES.match(nxt2):
                cur = section(m.group(1))
            pending = []
            continue

        m = INLINE.match(line)
        if m:
            cur = section(m.group(1))
            pending = []
            continue

        if line.startswith('#'):
            c = COMMENT.match(line)
            if c and cur is not None and c.group(1) == (
                    lines[i - 1].strip().lstrip('#').strip() if i else None):
                pass
            if c:
                pending.append(c.group(1))
            continue

        if not line:
            pending = []
            continue

        parts = line.split(None, 2)
        if parts[0] == 'map' and len(parts) >= 3:
            key, action = parts[1], parts[2]
        elif parts[0] == 'mouse_map':
            rest = line.split(None, 4)
            if len(rest) < 5:
                pending = []
                continue
            key, action = rest[1] + '-click', rest[4]
        else:
            pending = []
            continue

        # A known action always wins; a comment is only a fallback, and only
        # when it is a single short line sitting directly above the binding.
        note = describe(action)
        if note is None:
            note = pending[-1] if (len(pending) == 1 and len(pending[0]) <= 58) \
                else action
        if cur is None:
            cur = section('Other')
        cur.append((prettify_key(key), note))
        pending = []

    return [(n, byname[n]) for n in order if byname[n]]


def main():
    secs = parse()
    kw = min(max((len(k) for _, it in secs for k, _ in it), default=12), 20)
    nw = min(max((len(n) for _, it in secs for _, n in it), default=40), 52)
    rule = '\u2500' * (kw + nw + 3)

    out = ['']
    out.append('  %s%skitty%s%s \u2014 your keys%s' % (BOLD, ACCENT, OFF, BOLD, OFF))
    out.append('  %s%s%s' % (DIM, CONF.replace(os.path.expanduser('~'), '~'), OFF))
    out.append('')
    for name, items in secs:
        out.append('  %s%s%s' % (ACCENT, name, OFF))
        out.append('  %s%s%s' % (DIM, rule, OFF))
        for key, note in items:
            out.append('  %s%-*s%s  %s' % (KEYC, kw, key, OFF, note))
        out.append('')
    out.append('  %sForgot one?%s %sright-click%s %sor%s %sCtrl+Shift+M%s '
               '%sopens the full command palette.%s'
               % (DIM, OFF, KEYC, OFF, DIM, OFF, KEYC, OFF, DIM, OFF))
    out.append('  %sReload config after editing:%s %sCtrl+Shift+F5%s'
               % (DIM, OFF, KEYC, OFF))
    out.append('')
    text = '\n'.join(out)

    rows = shutil.get_terminal_size((100, 30)).lines
    if len(out) + 2 > rows and sys.stdout.isatty():
        import subprocess
        pager = subprocess.Popen(
            ['less', '-R', '-F', '-X'], stdin=subprocess.PIPE)
        pager.communicate(text.encode())
        return

    print(text)
    print(f'  {DIM}press any key to close{OFF}')
    try:
        import termios
        import tty
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            sys.stdin.read(1)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except Exception:
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            pass


if __name__ == '__main__':
    main()
