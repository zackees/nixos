"""Run using kitty +runpy with runpy.run_path("scripts/test-kitty-title-cache.py")."""
import runpy
import os
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import kitty.child as child
import kitty.tab_bar as tabs

tabs.config_dir = str(Path(__file__).resolve().parents[1] / 'home' / 'kitty')
tabs.clear_caches()
# The optional launch-origin bridge installs a native event-loop timer in a
# real terminal. This headless +runpy process has no Kitty UI/event loop.
with patch.dict(os.environ, XDG_RUNTIME_DIR=''):
    module = tabs.load_custom_draw_tab_module()
    pane = runpy.run_path(tabs.config_dir + '/window_title_bar.py')


class Window:
    def __init__(self, identifier):
        self.id = identifier
        self.child = SimpleNamespace(pid=identifier)
        self.screen = SimpleNamespace(last_reported_cwd='')
        self.exe = '/bin/claude'
        self.cwd = '/work/project'
        self.lookups = 0

    def get_exe_of_child(self):
        self.lookups += 1
        child.processes_in_group(7)
        return self.exe

    def get_cwd_of_child(self, oldest=False):
        child.processes_in_group(7)
        return self.cwd


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.now = 10.0
        module['_foreground_cache'].clear()
        child.process_data_cache.clear_cache()
        child.process_data_cache.cache_active = False
        self.patches = [
            patch.dict(module['_pane_exe'].__globals__, monotonic=lambda: self.now),
            patch('kitty.child.monotonic', lambda: self.now),
            patch('kitty.child.process_group_map', return_value=defaultdict(list, {7: [1, 2]})),
        ]
        for p in self.patches:
            self.addCleanup(p.stop)
        for p in self.patches:
            p.start()
        self.scan = child.process_group_map

    def test_redraws_reuse_lookup_and_different_panes_share_scan(self):
        windows = [Window(1), Window(2)]
        for _ in range(1000):
            for w in windows:
                self.assertEqual(module['_pane_exe'](w), 'claude')
                self.assertEqual(module['_pane_wd'](w), '/work/project')
        self.assertEqual([w.lookups for w in windows], [1, 1])
        self.assertEqual(self.scan.call_count, 1)

    def test_command_and_fallback_directory_refresh_after_ttl(self):
        w = Window(1)
        module['_pane_exe'](w)
        w.exe, w.cwd = '/bin/vim', '/work/new'
        self.assertEqual(module['_pane_exe'](w), 'claude')
        self.now += 0.51
        self.assertEqual(module['_pane_exe'](w), 'vim')
        self.assertEqual(module['_pane_wd'](w), '/work/new')
        self.assertEqual(self.scan.call_count, 2)

    def test_osc_directory_changes_are_immediate(self):
        w = Window(1)
        w.screen.last_reported_cwd = 'file:///first'
        self.assertEqual(module['_pane_wd'](w), '/first')
        w.screen.last_reported_cwd = 'file:///second'
        self.assertEqual(module['_pane_wd'](w), '/second')
        self.assertEqual(self.scan.call_count, 0)

    def test_existing_outer_cache_state_is_restored(self):
        child.process_data_cache.cache_active = True
        child.process_data_cache.ttl = 3
        module['_pane_exe'](Window(1))
        self.assertTrue(child.process_data_cache.cache_active)
        self.assertEqual(child.process_data_cache.ttl, 3)
        child.process_data_cache.ttl = 1

    def test_pane_and_tab_share_helpers_and_labels_survive(self):
        self.assertIs(pane['_pane_exe'], module['_pane_exe'])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.git').mkdir()
            (root / '.git/HEAD').write_text('ref: refs/heads/cache-test\n')
            w = Window(1)
            w.cwd = directory
            boss = SimpleNamespace(window_id_map={1: w})
            colors = SimpleNamespace(fg=SimpleNamespace(_fdbc4b='', window=''))
            with patch.dict(pane['draw_window_title'].__globals__, get_boss=lambda: boss, WindowTitleFormatter=colors):
                label = pane['draw_window_title'](SimpleNamespace(window_id=1, title='shell'))
            self.assertIn(root.name, label)
            self.assertIn('cache-test', label)
            self.assertIn('claude', label)


class BranchRefreshTests(unittest.TestCase):
    def setUp(self):
        module['_foreground_cache'].clear()
        self.now = 100.0

    def test_constant_title_refreshes_after_external_branch_switch_only_when_changed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.git').mkdir()
            head = root / '.git/HEAD'
            head.write_text('ref: refs/heads/feature\n')
            w = Window(900)
            w.screen.last_reported_cwd = 'file://' + directory
            w.show_title_bar = w.is_visible_in_layout = True
            labels = []
            data = SimpleNamespace(window_id=w.id, title='constant-agent-title')
            tab = SimpleNamespace(windows=[w])
            tab.update_window_title_bars = Mock(side_effect=lambda: labels.append(pane['draw_window_title'](data)))
            boss = SimpleNamespace(window_id_map={w.id: w},
                                   os_window_map={1: SimpleNamespace(active_tab=tab)})
            colors = SimpleNamespace(fg=SimpleNamespace(_fdbc4b='', window=''))
            install = pane.get('install_branch_refresh')
            self.assertTrue(callable(install), 'pane headers need an independent refresh timer')
            with patch.dict(pane['draw_window_title'].__globals__, get_boss=lambda: boss,
                            WindowTitleFormatter=colors, monotonic=lambda: self.now), \
                    patch('kitty.fast_data_types.add_timer', return_value=7) as add, \
                    patch('kitty.fast_data_types.remove_timer') as remove, \
                    patch('kitty.fast_data_types.mark_os_window_dirty'):
                labels.append(pane['draw_window_title'](data))
                install()
                refresh = add.call_args.args[0]
                refresh(7)
                self.assertEqual(tab.update_window_title_bars.call_count, 0)
                lookup = Mock(wraps=pane['_pane_wd'])
                with patch.dict(pane['draw_window_title'].__globals__, _pane_wd=lookup):
                    refresh(7)
                lookup.assert_not_called()  # No filesystem/foreground scan on an idle notification tick.
                stamp = head.stat().st_mtime_ns + 1_000_000_000
                head.write_text('ref: refs/heads/main\n')
                os.utime(head, ns=(stamp, stamp))
                refresh(7)
                self.assertIn('feature', labels[-1])  # Let settings settle before repainting.
                self.now += 0.1
                head.write_text('ref: refs/heads/main\n')
                refresh(7)  # A repeated event extends the quiet period.
                self.now += 0.15
                refresh(7)
                self.assertEqual(tab.update_window_title_bars.call_count, 0)
                self.now += 0.1
                refresh(7)
                self.assertIn('main', labels[-1])
                self.assertNotIn('feature', labels[-1])
                refresh(7)
                self.assertEqual(tab.update_window_title_bars.call_count, 1)
                # Simulate a missing notification: the slow catch-up still
                # discovers the next branch and restores its subscription.
                head.write_text('ref: refs/heads/catchup\n')
                with patch.object(boss.pane_branch_notifications, 'changed', return_value=False):
                    self.now += 31
                    refresh(7)
                self.assertIn('catchup', labels[-1])
                old = boss.pane_branch_notifications
                install()
                self.assertEqual(old.fd, -1)
                self.assertEqual(add.call_count, 2)
                remove.assert_called_once_with(7)
                boss.pane_branch_notifications.close()

    def test_notifications_filter_noise_survive_atomic_replacement_and_report_overflow(self):
        import struct
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            head = root / 'HEAD'
            head.write_text('before')
            events = pane['GitHeadNotifications']()
            self.addCleanup(events.close)
            events.subscribe(str(root), 'HEAD')
            (root / 'index').write_text('unrelated Git activity')
            self.assertFalse(events.changed())
            (root / 'HEAD.lock').write_text('after')
            (root / 'HEAD.lock').replace(head)
            self.assertTrue(events.changed())
            head.write_text('again')
            self.assertTrue(events.changed())
            with patch('os.read', return_value=struct.pack('iIII', -1, 0x4000, 0, 0)):
                self.assertTrue(events.changed())

    def test_event_burst_has_a_bounded_settling_delay(self):
        scan = Mock()
        with patch.dict(pane['_refresh_branch_titles'].__globals__,
                        _branch_notifications=SimpleNamespace(changed=lambda: True),
                        _next_branch_scan=130.0, _branch_pending_since=None, _branch_pending_until=None,
                        _scan_branch_titles=scan, monotonic=lambda: self.now):
            for tick in range(10):
                self.now = 100.0 + tick / 10
                pane['_refresh_branch_titles'](7)
            scan.assert_not_called()
            self.now = 101.01
            pane['_refresh_branch_titles'](7)
            scan.assert_called_once()

    def test_slow_catchup_without_notification_support(self):
        scan = Mock()
        with patch.dict(pane['_refresh_branch_titles'].__globals__,
                        _branch_notifications=None, _next_branch_scan=101.0,
                        _branch_pending_since=None, _branch_pending_until=None,
                        _scan_branch_titles=scan, monotonic=lambda: self.now):
            pane['_refresh_branch_titles'](7)
            scan.assert_not_called()
            self.now = 101.1
            pane['_refresh_branch_titles'](7)
            scan.assert_called_once()
            self.now = 102.0
            pane['_refresh_branch_titles'](7)
            scan.assert_called_once()

    def test_moved_directory_releases_kernel_subscription(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / 'metadata'
            metadata.mkdir()
            events = pane['GitHeadNotifications']()
            self.addCleanup(events.close)
            events.subscribe(str(metadata), 'HEAD')
            metadata.rename(root / 'moved')
            self.assertTrue(events.changed())
            self.assertEqual(events.watches, {})
            self.assertNotIn('inotify wd:', Path(f'/proc/self/fdinfo/{events.fd}').read_text())

    def test_worktree_detached_head_and_non_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            worktree = root / 'worktree'
            worktree.mkdir()
            gitdir = root / 'metadata'
            gitdir.mkdir()
            (worktree / '.git').write_text('gitdir: ../metadata\n')
            (gitdir / 'HEAD').write_text('ref: refs/heads/linked\n')
            self.assertEqual(pane['_branch'](str(worktree)), 'linked')
            stamp = (gitdir / 'HEAD').stat().st_mtime_ns + 1_000_000_000
            (gitdir / 'HEAD').write_text('0123456789abcdef\n')
            os.utime(gitdir / 'HEAD', ns=(stamp, stamp))
            self.assertEqual(pane['_branch'](str(worktree)), '0123456')
            self.assertEqual(pane['_branch'](str(root)), '')


suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(cls)
                           for cls in (CacheTests, BranchRefreshTests))
result = unittest.TextTestRunner(verbosity=2).run(suite)
if not result.wasSuccessful():
    raise SystemExit(1)
