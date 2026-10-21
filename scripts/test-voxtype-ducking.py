"""Playback ducking must restore levels without overriding manual changes."""
import runpy
from pathlib import Path
import tempfile
import unittest

Ducker = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'system/voxtype-ducking.py'))['Ducker']


class DuckingTests(unittest.TestCase):
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
