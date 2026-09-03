# Per-pane title bar: one line above each split naming its working directory.
# Reached from kitty.conf as `{custom}` in window_title_template.
#
# The tab bar can only ever label the ACTIVE pane, so a tab holding four
# Claude Code sessions in four different checkouts shows one directory and
# three blanks, and you have to focus a pane to find out where it is.
#
# kitty hands this function a WindowTitleData carrying the window's OSC 2
# title and no directory at all. That title is the wrong source anyway: with
# shell integration it flips between the cwd at the prompt and the *name of
# the running command* while one runs, so the directory would go missing from
# a pane exactly while a long job makes you want to know which pane it is in.
# Resolve the window by id instead and ask kitty for the cwd it tracks from
# OSC 7, which is always current. tab_bar.py's draw_title() does the same, so
# a pane's label and its tab's label agree by construction.
import os
import runpy

from kitty.boss import get_boss
from kitty.constants import config_dir

# _short_wd and SHELLS live in tab_bar.py, and are shared rather than copied
# so the two labels cannot drift apart. kitty loads both of these files with
# runpy.run_path and never puts the config directory on sys.path, so this is
# the import: tab_bar.py's body only defines constants and functions, and
# running it a second time has no effect beyond that.
_tab_bar = runpy.run_path(os.path.join(config_dir, 'tab_bar.py'))
_short_wd = _tab_bar['_short_wd']
SHELLS = _tab_bar['SHELLS']


def draw_window_title(data):
    """`~/dev/nixos` at a prompt, `~/dev/nixos - claude` while a command runs.

    Never returns the empty string. kitty zeroes the title bar's geometry when
    the template evaluates to nothing, so an empty result here does not print a
    blank label -- it makes the whole bar disappear, which reads as the feature
    being broken rather than as one pane having nothing to say.
    """
    w = get_boss().window_id_map.get(data.window_id)
    wd = (w.get_cwd_of_child() if w is not None else '') or ''
    if not wd:
        # ssh, a `launch`ed pager, any child that never reported a directory.
        return ' %s' % (data.title or '…')
    exe = os.path.basename((w.get_exe_of_child() if w is not None else '') or '')
    if exe and exe not in SHELLS:
        return ' %s · %s' % (_short_wd(wd), exe)
    return ' %s' % _short_wd(wd)
