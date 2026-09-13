"""Run with kitty +runpy 'import runpy; runpy.run_path("scripts/test-kitty-mouse-paste.py")'."""
import runpy
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
PASTE = runpy.run_path(str(ROOT / 'home/kitty/paste.py'))
HANDLE = PASTE['handle_result']
GLOBALS = PASTE['paste_into'].__globals__


class MousePasteTests(unittest.TestCase):
    def test_issue_17_popup_has_compositor_parent_and_no_global_topmost(self):
        self.assertNotIn("root.attributes('-topmost', True)", PASTE['POPUP_CODE'])
        self.assertIn('KWIN_CODE', PASTE)

    def setUp(self):
        self.window = Mock()
        self.boss = SimpleNamespace(window_id_map={42: self.window}, confirm=Mock())
        popup = patch.dict(GLOBALS, _confirm_popup=lambda boss, msg, cb, window: boss.confirm(msg, cb))
        popup.start()
        self.addCleanup(popup.stop)

    def invoke(self, confirm=False):
        HANDLE(['paste.py'] + (['--confirm'] if confirm else []), None, 42, self.boss)

    def test_direct_text_uses_normal_clipboard_and_no_confirmation(self):
        with patch.dict(GLOBALS, _clipboard_image=lambda: None), \
                patch('kitty.clipboard.get_clipboard_string', return_value='hello\nworld'):
            self.invoke()
        self.window.paste_text.assert_called_once_with('hello\nworld')
        self.boss.confirm.assert_not_called()

    def test_direct_image_quotes_saved_path(self):
        with patch.dict(GLOBALS, _clipboard_image=lambda: (b'image', 'png'),
                        _save_image=lambda data, ext: '/tmp/an image.png'):
            self.invoke()
        self.window.paste_text.assert_called_once_with("'/tmp/an image.png'")

    def test_cancel_reads_metadata_but_does_not_save_or_paste(self):
        save = Mock()
        with patch.dict(GLOBALS, _clipboard_image=lambda: (b'x' * 1234, 'png'),
                        _save_image=save):
            self.invoke(True)
            self.boss.confirm.call_args.args[1](False)
        save.assert_not_called()
        self.assertEqual(self.boss.confirm.call_args.args[0], 'Paste image (2kB) [y/n]')
        self.window.paste_text.assert_not_called()

    def test_confirmed_image_targets_original_pane(self):
        with patch.dict(GLOBALS, _clipboard_image=lambda: (b'image', 'png'),
                        _save_image=lambda data, ext: '/tmp/image.png'):
            self.invoke(True)
            self.boss.active_window = Mock()
            self.boss.confirm.call_args.args[1](True)
        self.window.paste_text.assert_called_once_with('/tmp/image.png')
        self.boss.active_window.paste_text.assert_not_called()

    def test_confirmed_text(self):
        with patch.dict(GLOBALS, _clipboard_image=lambda: None), \
                patch('kitty.clipboard.get_clipboard_string', return_value='text'):
            self.invoke(True)
            self.boss.confirm.call_args.args[1](True)
        self.window.paste_text.assert_called_once_with('text')

    def test_closed_pane_is_not_pasted_into(self):
        with patch.dict(GLOBALS, _read_clipboard=lambda: ('text', 'old', '')):
            self.invoke(True)
        self.boss.window_id_map.clear()
        self.boss.confirm.call_args.args[1](True)
        self.window.paste_text.assert_not_called()

    def test_text_size_counts_utf8_bytes(self):
        self.assertEqual(PASTE['_prompt'](('text', 'é' * 600, '')),
                         'Paste text (2kB) [y/n]')
        self.assertEqual(PASTE['_prompt'](('text', '', '')), 'Paste text (0kB) [y/n]')
        self.assertEqual(PASTE['_prompt'](('image', b'x' * 1000, 'png')),
                         'Paste image (1kB) [y/n]')

    def test_clipboard_change_does_not_change_confirmed_payload(self):
        read = Mock(return_value=('text', 'original', ''))
        with patch.dict(GLOBALS, _read_clipboard=read):
            self.invoke(True)
            read.return_value = ('text', 'replacement', '')
            self.boss.confirm.call_args.args[1](True)
        read.assert_called_once()
        self.window.paste_text.assert_called_once_with('original')

    def test_image_files_are_unique_and_match_payload(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(GLOBALS, SAVE_DIR=directory):
            first = PASTE['_save_image'](b'first', 'png')
            second = PASTE['_save_image'](b'second', 'png')
            self.assertNotEqual(first, second)
            self.assertEqual(Path(first).read_bytes(), b'first')
            self.assertEqual(Path(second).read_bytes(), b'second')

    def test_native_popup_runs_without_blocking_and_fails_closed(self):
        boss = SimpleNamespace(run_background_process=Mock(), show_error=Mock())
        callback = Mock()
        with patch.dict(GLOBALS, _source_identity=lambda window: dict(pid=123, title='source')):
            PASTE['_confirm_popup'](boss, 'Paste text (1kB) [y/n]', callback, self.window)
        callback.assert_not_called()
        args = boss.run_background_process.call_args
        self.assertEqual(args.args[0][3], 'Paste text (1kB) [y/n]')
        self.assertIn('"pid": 123', args.args[0][-1])
        self.assertIn('"title": "source"', args.args[0][-1])
        finished = args.kwargs['notify_on_death']
        for status, error, expected in [(0, None, True), (1, None, False),
                                        (9, None, False), (-1, OSError('missing'), False)]:
            finished(status, error)
            callback.assert_called_with(expected)

    def test_bindings_cover_grabbed_and_ungrabbed(self):
        from kitty.options.utils import parse_mouse_map
        conf = (ROOT / 'home/kitty/kitty.conf').read_text()
        for button, action in [('right', 'kitten paste.py --confirm'),
                               ('middle', 'kitten paste.py')]:
            for event, expected in [('press', 'discard_event'), ('release', action)]:
                mapping = f'{button} {event} grabbed,ungrabbed {expected}'
                self.assertIn('mouse_map ' + mapping, conf)
                self.assertEqual(len(list(parse_mouse_map(mapping))), 2)


result = unittest.TextTestRunner(verbosity=2).run(
    unittest.defaultTestLoader.loadTestsFromTestCase(MousePasteTests))
if not result.wasSuccessful():
    raise SystemExit(1)
