# Custom tab bar: stock powerline tabs, plus a permanent reminder on the
# right telling you where the cheat sheet and the command palette live.
import os
import runpy
from time import monotonic

from kitty.tab_bar import as_rgb, draw_tab_with_powerline
from kitty.window_title_bar import clear_caches as clear_pane_title_cache

# Kitty reloads this module on SIGUSR1 but does not invalidate the custom pane
# title module itself. Invalidate it here so both title renderers reload together.
clear_pane_title_cache()

# kitty-worker's client first: everything below asks it instead of touching
# /proc or the disk on kitty's main thread, which draws every terminal (see
# system/kitty-worker). Reloaded with this module on SIGUSR1.
_worker_client = '/run/current-system/sw/share/kitty-worker/kitty_async.py'
_worker = None
if os.path.isfile(_worker_client):  # io-ok: module load, not a timer or draw
    try:
        _worker = runpy.run_path(_worker_client)['install']()
    except Exception:
        _worker = None  # Without it labels go stale; terminals still draw.

# Reloading kitty re-imports this module even for already open windows. The
# helper publishes read-only pane identities for launch placement (issue #14).
_origin_bridge = '/run/current-system/sw/share/launch-origin/kitty_bridge.py'
if os.path.isfile(_origin_bridge):  # io-ok: module load
    try:
        runpy.run_path(_origin_bridge)['install']()
    except Exception:
        pass  # An optional placement helper must not break the tab bar.

# Saves each OS window as a session so kitty-resurrect can bring them back
# after a crash, onto the screen and desktop they were on.
_resurrect = '/run/current-system/sw/share/kitty-resurrect/kitty_snapshot.py'
if os.path.isfile(_resurrect):  # io-ok: module load
    try:
        runpy.run_path(_resurrect)['install']()
    except Exception:
        pass  # Crash recovery must not break the tab bar either.

KEY = 0xfdbc4b   # amber, matches color11
LBL = 0x7f8c8d   # Breeze inactive-tab grey

# (text, colour) segments, drawn right-aligned after the last tab
HINT = (
    ('  Super+/ ', KEY), ('keys', LBL),
    ('   Ctrl+Shift+M ', KEY), ('menu  ', LBL),
)
HINT_LEN = sum(len(t) for t, _ in HINT)


HOME = os.path.expanduser('~')
# Foreground processes that mean "sitting at a prompt", not "running something".
SHELLS = frozenset(('bash', 'zsh', 'fish', 'sh', 'dash', 'ksh'))
# Leading elision when the path is deeper than this many components.
WD_MAX_PARTS = 4

# The foreground program and fallback directory come from kitty-worker's last
# reply (offline() swaps kitty's /proc lookups for it), never from /proc on
# this thread. Cached per pane for 500 ms; OSC 7 directories stay immediate.
FOREGROUND_TTL = 0.5
_foreground_cache = {}


def _foreground_info(w):
    if w is None:
        return '', ''
    key = (w.id, w.child.pid)
    now = monotonic()
    cached = _foreground_cache.get(key)
    if cached is not None and now - cached[0] < FOREGROUND_TTL:
        return cached[1], cached[2]

    if _worker is None:
        return '', ''
    with _worker.offline():
        exe = os.path.basename(w.get_exe_of_child() or '')
        wd = w.get_cwd_of_child(oldest=True) or w.get_cwd_of_child() or ''
    if len(_foreground_cache) >= 256:
        _foreground_cache.clear()
    # Start the TTL after the lookup so even a slow scan cannot consume it.
    _foreground_cache[key] = (monotonic(), exe, wd)
    return exe, wd


def _pane_exe(w):
    return _foreground_info(w)[0]


def _short_wd(wd):
    """`/home/niteris/dev/nixos` -> `~/dev/nixos`, deep paths elided in front."""
    if wd == HOME:
        return '~'
    if wd.startswith(HOME + os.sep):
        wd = '~' + wd[len(HOME):]
    parts = wd.split(os.sep)
    if len(parts) > WD_MAX_PARTS:
        parts = ['\u2026'] + parts[-(WD_MAX_PARTS - 1):]
    return os.sep.join(parts) or os.sep


def _pane_wd(w):
    """The directory a pane should be labelled with, for kitty Window `w`.

    Not `get_cwd_of_child()`: that is the cwd of the *foreground* process, so
    while Claude Code shells out to `wl-copy` (spawned with cwd `/`) every
    label flipped to `/ · wl-copy`. Prefer, in order: the directory the shell
    last reported over OSC 7 (shell integration; stays put while children
    run), the cwd of the oldest child (the shell itself), and only then the
    foreground process.
    """
    if w is None:
        return ''
    try:
        from kitty.window import path_from_osc7_url
        reported = w.screen.last_reported_cwd
        if reported:
            wd = path_from_osc7_url(reported)
            if wd:
                return wd
    except Exception:
        pass
    return _foreground_info(w)[1]


def draw_title(data):
    """Tab label, reached from kitty.conf as `{custom}` in tab_title_template.

    kitty's own `{title}` is whatever the shell last set with OSC 2, which its
    shell integration flips between the cwd at the prompt and the *name of the
    running command* while one runs -- so the directory disappears exactly when
    a long build makes you want to know which tab it is in. Take the directory
    from kitty's own OSC 7 tracking instead, which is always current, and add
    the command beside it rather than in place of it.

    Falls back to `{title}` when kitty has no cwd for the window: ssh, a pager
    launched with `launch`, or any child that never reported one.
    """
    tab = data['tab']
    # tab.active_wd is the foreground process's cwd (see _pane_wd); resolve
    # the active window and ask for the shell's directory instead.
    w = None
    wd = ''
    try:
        from kitty.boss import get_boss
        live_tab = get_boss().tab_for_id(tab.tab_id)
        w = live_tab.active_window if live_tab is not None else None
        wd = _pane_wd(w)
    except Exception:
        wd = ''
    if not wd:
        return data['title']
    exe = _pane_exe(w)
    if exe and exe not in SHELLS:
        return '%s \u00b7 %s' % (_short_wd(wd), exe)
    return _short_wd(wd)


def draw_tab(draw_data, screen, tab, before, max_tab_length, index, is_last,
             extra_data):
    end = draw_tab_with_powerline(
        draw_data, screen, tab, before, max_tab_length, index, is_last,
        extra_data)
    # for_layout passes measure tab widths via cursor.x - never draw then.
    if is_last and not extra_data.for_layout:
        start = screen.columns - HINT_LEN
        if start > screen.cursor.x + 1:
            screen.cursor.x = start
            screen.cursor.bg = as_rgb(int(draw_data.default_bg))
            screen.cursor.bold = screen.cursor.italic = False
            for text, colour in HINT:
                screen.cursor.fg = as_rgb(colour)
                screen.draw(text)
    return end
