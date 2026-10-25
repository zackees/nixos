# Per-pane title bar: one line above each split naming its working directory
# and git branch. Reached from kitty.conf as `{custom}` in
# window_title_template.
#
# The tab bar could only ever label the ACTIVE pane, so a tab holding four
# Claude Code sessions in four different checkouts showed one directory and
# three blank corners -- and the one it did show sat directly above a
# *different* pane, which read as a contradiction rather than as a label. The
# tab bar is now hidden until a second tab exists and this is what names a
# pane.
#
# kitty hands this function a WindowTitleData carrying the window's OSC 2
# title and no directory at all. That title is the wrong source anyway: with
# shell integration it flips between the cwd at the prompt and the *name of
# the running command* while one runs, so the directory would go missing from
# a pane exactly while a long job made you want to know which pane it was in.
# Resolve the window by id instead and ask kitty for the cwd it tracks from
# OSC 7, which is always current. tab_bar.py's draw_title() does the same, so
# a pane's label and its tab's label agree by construction.

from kitty.boss import get_boss
from kitty.tab_bar import load_custom_draw_tab_module
from kitty.window_title_bar import WindowTitleFormatter

# Share the loaded tab module, including its foreground cache, rather than
# executing a second copy with a separate cache and duplicate startup hooks.
_tab_bar = load_custom_draw_tab_module()
_short_wd = _tab_bar['_short_wd']
_pane_wd = _tab_bar['_pane_wd']
_pane_exe = _tab_bar['_pane_exe']
SHELLS = _tab_bar['SHELLS']

# Nerd Font branch glyph -- the same one starship draws in the prompt below.
BRANCH_GLYPH = ''
# Amber, matching the key hints in tab_bar.py.
BRANCH_COLOUR = '_fdbc4b'
# perf/mp3-imdct-constant-multiplies is a real branch name here, and long
# enough to push the command name off the end of a narrow pane. The bar clips
# rather than wraps, so cap the part that can run away.
BRANCH_MAX = 22

# Caption identity at its last render. A TUI can keep OSC 2 unchanged while
# its agent switches Git branches, so ordinary title events are insufficient:
# each kitty-worker reply re-checks every visible pane.
_rendered_branches = {}


def _branch(wd):
    """The git branch for `wd`, from kitty-worker's last reply ('' until then).

    Finding it means walking up for `.git` and reading HEAD -- filesystem
    work, which on this thread (kitty's main thread, drawing every terminal)
    froze them all whenever the disk was busy. kitty-worker does it instead.
    """
    worker = _tab_bar.get('_worker')
    return worker.branch(wd) if worker is not None else ''


def _scan_branch_titles():
    """After a worker reply: redraw any visible caption whose branch changed."""
    from kitty.fast_data_types import mark_os_window_dirty

    boss = get_boss()
    if boss is None:
        return
    for os_id, manager in boss.os_window_map.items():
        tab = manager.active_tab
        if tab is None:
            continue
        changed = False
        for window in tab.windows:
            if not window.is_visible_in_layout or not window.show_title_bar:
                continue
            wd = _pane_wd(window)
            identity = (wd, _branch(wd) if wd else '')
            if _rendered_branches.get(window.id) != identity:
                # This uses Kitty's own focus/group handling and retains the
                # caption's activity, progress and attention indicators.
                changed = True
        if changed:
            tab.update_window_title_bars()
            mark_os_window_dirty(os_id)
    for identifier in tuple(_rendered_branches):
        if identifier not in boss.window_id_map:
            del _rendered_branches[identifier]


def install_branch_refresh():
    boss = get_boss()
    if boss is None:  # Also permits headless +runpy unit tests.
        return
    # Retire what earlier versions of this module installed.
    from kitty.fast_data_types import remove_timer
    if (old := getattr(boss, 'pane_branch_refresh_timer', None)) is not None:
        remove_timer(old)
        boss.pane_branch_refresh_timer = None
    if old_notifications := getattr(boss, 'pane_branch_notifications', None):
        old_notifications.close()
        boss.pane_branch_notifications = None
    worker = _tab_bar.get('_worker')
    if worker is not None:
        worker.listeners[:] = [f for f in worker.listeners
                               if getattr(f, '__name__', '') != '_scan_branch_titles']
        worker.listeners.append(_scan_branch_titles)


def draw_window_title(data):
    """`~/dev/nixos  main` at a prompt, plus ` · claude` while a command runs.

    Never returns the empty string. kitty zeroes the title bar's geometry when
    the template evaluates to nothing, so an empty result here does not print a
    blank label -- it makes the whole bar disappear, which reads as the feature
    being broken rather than as one pane having nothing to say.
    """
    w = get_boss().window_id_map.get(data.window_id)
    # The shell's directory (OSC 7, then the oldest child), not the foreground
    # process's: a transient `wl-copy` from Claude Code runs with cwd `/` and
    # used to relabel the pane `/ · wl-copy`. See _pane_wd in tab_bar.py.
    wd = _pane_wd(w)
    branch = _branch(wd) if wd else ''
    _rendered_branches[data.window_id] = (wd, branch)
    if not wd:
        # ssh, a `launch`ed pager, any child that never reported a directory.
        return ' %s' % (data.title or '…')

    out = [' ', _short_wd(wd)]
    if branch:
        # fmt.fg.window is the bar's own foreground for this pane's focus
        # state; kitty sets that up immediately before calling this function,
        # so it is the correct way back to normal after the amber.
        out.append(' %s%s %s%s' % (
            getattr(WindowTitleFormatter.fg, BRANCH_COLOUR), BRANCH_GLYPH,
            branch, WindowTitleFormatter.fg.window))
    exe = _pane_exe(w)
    if exe and exe not in SHELLS:
        out.append(' · %s' % exe)
    return ''.join(out)


install_branch_refresh()
