"""Run using kitty +runpy with runpy.run_path("scripts/test-kitty-title-cache.py")."""
import runpy
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import kitty.child as child
import kitty.tab_bar as tabs

tabs.config_dir = str(Path(__file__).resolve().parents[1] / 'home' / 'kitty')
tabs.clear_caches()
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


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CacheTests))
if not result.wasSuccessful():
    raise SystemExit(1)
