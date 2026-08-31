# Custom tab bar: stock powerline tabs, plus a permanent reminder on the
# right telling you where the cheat sheet and the command palette live.
import os

from kitty.tab_bar import as_rgb, draw_tab_with_powerline

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
    wd = tab.active_wd
    if not wd:
        return data['title']
    exe = tab.active_exe
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
