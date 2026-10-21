"""Playback ducking must restore levels without overriding manual changes."""
import runpy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, call, patch

module = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'system/voxtype-ducking.py'))
Ducker = module['Ducker']


class DuckingTests(unittest.TestCase):
    def preparation(self, statuses):
        main = module['main']
        duck = Mock()
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(main.__globals__, {
                'Ducker': Mock(return_value=duck),
                'watcher_running': Mock(side_effect=statuses),
            }), patch.dict('os.environ', {'XDG_RUNTIME_DIR': directory}), patch(
                'sys.argv', ['ducker', '--prepare']
            ):
                main()
        return duck

    def test_prepare_respects_stopped_watcher(self):
        duck = self.preparation([False])
        duck.update.assert_not_called()

    def test_prepare_restores_if_watcher_stops_during_preparation(self):
        duck = self.preparation([True, False])
        self.assertEqual(duck.update.call_args_list, [call(True), call(False)])

    def test_prepare_and_watcher_do_not_double_duck(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'levels.json'
            nodes = {'speaker': {'id': 10, 'volumes': [0.5, 0.25]}}
            def change(node, volumes):
                nodes['speaker']['volumes'] = volumes
            watcher = Ducker(path, lambda: nodes, change)
            hook = Ducker(path, lambda: nodes, change)
            hook.update(True)
            watcher.reload()
            watcher.update(True)
            self.assertEqual(nodes['speaker']['volumes'], [0.125, 0.0625])
            watcher.update(False)
            self.assertEqual(nodes['speaker']['volumes'], [0.5, 0.25])

    def test_watcher_recovers_preparation_it_did_not_observe(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'levels.json'
            nodes = {'speaker': {'id': 10, 'volumes': [0.5]}}
            def change(node, volumes):
                nodes['speaker']['volumes'] = volumes
            watcher = Ducker(path, lambda: nodes, change)
            Ducker(path, lambda: nodes, change).update(True)
            # A failed or very short capture may return to idle between polls.
            watcher.reload()
            watcher.update(False)
            self.assertEqual(nodes['speaker']['volumes'], [0.5])
            self.assertEqual(watcher.saved, {})

    def test_restore_balance_and_device_added_during_recording(self):
        with tempfile.TemporaryDirectory() as directory:
            nodes = {'speaker': {'id': 10, 'volumes': [0.5, 0.25]}}
            def change(node, volumes):
                next(n for n in nodes.values() if n['id'] == node)['volumes'] = volumes
            duck = Ducker(Path(directory) / 'levels.json', lambda: nodes, change)
            duck.update(True)
            self.assertEqual(nodes['speaker']['volumes'], [0.125, 0.0625])
            duck.update(True)
            self.assertEqual(nodes['speaker']['volumes'], [0.125, 0.0625])
            nodes['headphones'] = {'id': 11, 'volumes': [1.0, 1.0]}
            duck.update(True)
            self.assertEqual(nodes['headphones']['volumes'], [0.25, 0.25])
            duck.update(False)
            self.assertEqual(nodes['speaker']['volumes'], [0.5, 0.25])
            self.assertEqual(nodes['headphones']['volumes'], [1.0, 1.0])
            self.assertEqual(duck.saved, {})

    def test_manual_volume_changes_win(self):
        with tempfile.TemporaryDirectory() as directory:
            nodes = {'speaker': {'id': 10, 'volumes': [0.5, 0.5]}}
            def change(node, volumes):
                nodes['speaker']['volumes'] = volumes
            duck = Ducker(Path(directory) / 'levels.json', lambda: nodes, change)
            duck.update(True)
            nodes['speaker']['volumes'] = [0.3, 0.3]
            duck.update(False)
            self.assertEqual(nodes['speaker']['volumes'], [0.3, 0.3])

    def test_crash_recovery_and_reconnected_device_use_name_not_reused_id(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'levels.json'
            nodes = {'speaker': {'id': 10, 'volumes': [0.5, 0.5]}}
            def change(node, volumes):
                nodes['speaker']['volumes'] = volumes
            duck = Ducker(path, lambda: nodes, change)
            duck.update(True)
            del nodes['speaker']
            recovered = Ducker(path, lambda: nodes, change)
            recovered.update(False)
            self.assertIn('speaker', recovered.saved)
            nodes['speaker'] = {'id': 99, 'volumes': [0.125, 0.125]}
            recovered.update(False)
            self.assertEqual(nodes['speaker']['volumes'], [0.5, 0.5])


if __name__ == '__main__':
    unittest.main()
