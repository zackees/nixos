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
import os
import stat
import struct
from time import monotonic

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

# wd -> (path that was stat'd, its mtime then, branch name). Cleared wholesale
# rather than aged: only a handful of directories are ever live at once, and
# rebuilding an entry costs two stats.
_branch_cache = {}
BRANCH_CACHE_MAX = 64
# Caption identity at its last render. A TUI can keep OSC 2 unchanged while
# its agent switches Git branches, so ordinary title events are insufficient.
_rendered_branches = {}
BRANCH_REFRESH_INTERVAL = 0.25
BRANCH_CATCHUP_INTERVAL = 30.0
BRANCH_SETTLE_DELAY = 0.2
BRANCH_MAX_DELAY = 1.0
_branch_notifications = None
_next_branch_scan = 0.0
_branch_pending_since = None
_branch_pending_until = None


class GitHeadNotifications:
    """One nonblocking inotify descriptor per Kitty process, shared by panes.

    Monitor directories, not HEAD inodes: Git replaces HEAD by renaming its
    lock file. Filter out unrelated index/log activity before requesting work.
    """
    MASK = 0x2 | 0x4 | 0x8 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800

    def __init__(self):
        import ctypes
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.inotify_init1.argtypes = [ctypes.c_int]
        self.libc.inotify_init1.restype = ctypes.c_int
        self.libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self.libc.inotify_add_watch.restype = ctypes.c_int
        self.libc.inotify_rm_watch.argtypes = [ctypes.c_int, ctypes.c_int]
        self.libc.inotify_rm_watch.restype = ctypes.c_int
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), 'inotify_init1 failed')
        self.watches = {}
        self.descriptors = {}

    def subscribe(self, directory, name):
        if self.fd < 0:
            return
        if directory not in self.watches:
            wd = self.libc.inotify_add_watch(self.fd, os.fsencode(directory), self.MASK)
            if wd < 0:
                return  # Unavailable paths are retried by the catch-up scan.
            self.watches[directory] = (wd, set())
            self.descriptors.setdefault(wd, set()).add(directory)
        self.watches[directory][1].add(name)

    def sync(self, wanted):
        directories = {directory for directory, _ in wanted}
        for directory in tuple(self.watches):
            if directory not in directories:
                wd, _ = self.watches.pop(directory)
                self.descriptors[wd].discard(directory)
                if not self.descriptors[wd]:
                    del self.descriptors[wd]
                    self.libc.inotify_rm_watch(self.fd, wd)

    def changed(self):
        if self.fd < 0:
            return False
        try:
            data = os.read(self.fd, 65536)
        except BlockingIOError:
            return False
        except OSError:
            self.close()
            return True
        changed = False
        offset = 0
        while offset + 16 <= len(data):
            wd, mask, _cookie, length = struct.unpack_from('iIII', data, offset)
            name = os.fsdecode(data[offset + 16:offset + 16 + length].split(b'\0', 1)[0])
            offset += 16 + length
            if mask & 0x4000:  # IN_Q_OVERFLOW: reconcile everything after settling.
                changed = True
            if mask & (0x8000 | 0x400 | 0x800):  # ignored, delete-self, move-self
                directories = self.descriptors.pop(wd, ())
                if directories:
                    for directory in directories:
                        self.watches.pop(directory, None)
                    if not mask & 0x8000:
                        self.libc.inotify_rm_watch(self.fd, wd)
                    changed = True
            else:
                for directory in self.descriptors.get(wd, ()):
                    if name in self.watches[directory][1]:
                        changed = True
        return changed

    def close(self):
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1
        self.watches.clear()
        self.descriptors.clear()


def _track_branch_watch(wd):
    if _branch_notifications is None or not wd:
        return None
    # _branch just populated this entry. Reuse it instead of walking the
    # filesystem again on every ordinary caption render.
    entry = _branch_cache.get(wd)
    target = entry[0] if entry else (_git_head(wd) or wd)
    directory, name = (os.path.dirname(target), 'HEAD') if target != wd else (wd, '.git')
    directory = os.path.abspath(directory)
    _branch_notifications.subscribe(directory, name)
    return directory, name


def _refresh_branch_titles(_timer_id):
    global _next_branch_scan, _branch_pending_since, _branch_pending_until
    now = monotonic()
    if _branch_notifications is not None and _branch_notifications.changed():
        if _branch_pending_since is None:
            _branch_pending_since = now
        _branch_pending_until = min(now + BRANCH_SETTLE_DELAY, _branch_pending_since + BRANCH_MAX_DELAY)
    if _branch_pending_until is not None:
        if now < _branch_pending_until:
            return
    elif now < _next_branch_scan:
        return
    # Kitty's Python API has no fd-read callback. Its UI timer drains the
    # notification queue cheaply; repository/proc scans happen only after a
    # settled event or the slow catch-up deadline, never on every tick.
    if now >= _next_branch_scan:
        _next_branch_scan = now + BRANCH_CATCHUP_INTERVAL
    _branch_pending_since = _branch_pending_until = None
    _branch_cache.clear()  # Also catches atomic replacements with preserved mtimes.
    _scan_branch_titles()


def _scan_branch_titles():
    from kitty.fast_data_types import mark_os_window_dirty

    boss = get_boss()
    if boss is None:
        return
    wanted = set()
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
            if subscription := _track_branch_watch(wd):
                wanted.add(subscription)
            if _rendered_branches.get(window.id) != identity:
                # This uses Kitty's own focus/group handling and retains the
                # caption's activity, progress and attention indicators.
                changed = True
        if changed:
            tab.update_window_title_bars()
            mark_os_window_dirty(os_id)
    if _branch_notifications is not None:
        _branch_notifications.sync(wanted)
    for identifier in tuple(_rendered_branches):
        if identifier not in boss.window_id_map:
            del _rendered_branches[identifier]


def install_branch_refresh():
    global _branch_notifications, _next_branch_scan, _branch_pending_since, _branch_pending_until
    from kitty.fast_data_types import add_timer, remove_timer

    boss = get_boss()
    if boss is None:  # Also permits headless +runpy unit tests.
        return
    old = getattr(boss, 'pane_branch_refresh_timer', None)
    if old is not None:
        remove_timer(old)
    if old_notifications := getattr(boss, 'pane_branch_notifications', None):
        old_notifications.close()
    try:
        _branch_notifications = GitHeadNotifications()
    except (OSError, AttributeError):
        _branch_notifications = None  # Polling still catches up without inotify.
    boss.pane_branch_notifications = _branch_notifications
    _next_branch_scan = 0.0
    _branch_pending_since = _branch_pending_until = None
    # Keep all Kitty window access on its UI thread. Store the handle on the
    # boss so reloading this module replaces, rather than duplicates, it.
    boss.pane_branch_refresh_timer = add_timer(_refresh_branch_titles, BRANCH_REFRESH_INTERVAL, True)


def _git_head(wd):
    """Path of the HEAD file governing `wd`, or None outside a repository.

    Walks up looking for `.git`. A directory is the ordinary case; a *file*
    holding `gitdir: <path>` is a linked worktree or a submodule, which is not
    an exotic case here -- a lot of the work on this machine happens in
    worktrees, and reading `<repo>/.git/HEAD` unconditionally would report the
    main checkout's branch for every one of them.
    """
    d = wd
    while True:
        g = os.path.join(d, '.git')
        try:
            st = os.lstat(g)
        except OSError:
            pass
        else:
            if stat.S_ISDIR(st.st_mode):
                return os.path.join(g, 'HEAD')
            try:
                with open(g, encoding='utf-8', errors='replace') as f:
                    line = f.read(4096).strip()
            except OSError:
                return None
            if not line.startswith('gitdir:'):
                return None
            p = line[len('gitdir:'):].strip()
            if not os.path.isabs(p):
                p = os.path.join(d, p)
            return os.path.join(p, 'HEAD')
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _branch(wd):
    """Current branch for `wd`, or '' outside a repository.

    Read out of HEAD rather than by running git. This is called for every pane
    every time *any* pane's title changes, which with a few Claude Code
    sessions running is several times a second; forking git that often to
    learn one line would be absurd.

    The cache is invalidated on the mtime of whatever was stat'd: HEAD for a
    repository, so a checkout appears at once, and the directory itself when
    there is no repository, so `git init` appears too -- creating `.git` bumps
    its parent's mtime.
    """
    ent = _branch_cache.get(wd)
    if ent is not None:
        target, mtime, name = ent
        try:
            if os.stat(target).st_mtime == mtime:
                return name
        except OSError:
            pass

    head = _git_head(wd)
    target, name = head or wd, ''
    if head is not None:
        try:
            with open(head, encoding='utf-8', errors='replace') as f:
                line = f.read(256).strip()
        except OSError:
            target = wd
        else:
            if line.startswith('ref: refs/heads/'):
                name = line[len('ref: refs/heads/'):]
            elif line.startswith('ref: '):
                name = line[len('ref: '):]
            else:
                name = line[:7]     # detached: the short sha, as git shows it
            if len(name) > BRANCH_MAX:
                name = name[:BRANCH_MAX - 1] + '…'
    try:
        _branch_cache[wd] = (target, os.stat(target).st_mtime, name)
    except OSError:
        pass
    if len(_branch_cache) > BRANCH_CACHE_MAX:
        _branch_cache.clear()
    return name


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
    _track_branch_watch(wd)
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
