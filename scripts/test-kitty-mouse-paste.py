"""Run with kitty +runpy 'import runpy; runpy.run_path("scripts/test-kitty-mouse-paste.py")'."""
import runpy
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
PASTE = runpy.run_path(str(ROOT / 'home/kitty/paste.py'))
HANDLE = PASTE['handle_result']
GLOBALS = PASTE['paste_into'].__globals__


class MousePasteTests(unittest.TestCase):
    def setUp(self):
        self.window = Mock()
        self.boss = SimpleNamespace(window_id_map={42: self.window}, confirm=Mock())

    def invoke(self, confirm=False):
        HANDLE(['paste.py'] + (['--confirm'] if confirm else []), None, 42, self.boss)

    def test_direct_text_uses_normal_clipboard_and_no_confirmation(self):
        with patch.dict(GLOBALS, _clipboard_image_path=lambda: None), \
                patch('kitty.clipboard.get_clipboard_string', return_value='hello\nworld'):
            self.invoke()
        self.window.paste_text.assert_called_once_with('hello\nworld')
        self.boss.confirm.assert_not_called()

    def test_direct_image_quotes_saved_path(self):
        with patch.dict(GLOBALS, _clipboard_image_path=lambda: '/tmp/an image.png'):
            self.invoke()
        self.window.paste_text.assert_called_once_with("'/tmp/an image.png'")

    def test_cancel_does_not_read_clipboard(self):
        read = Mock()
        with patch.dict(GLOBALS, _clipboard_image_path=read):
            self.invoke(True)
            self.boss.confirm.call_args.args[1](False)
        read.assert_not_called()
        self.window.paste_text.assert_not_called()
        self.assertFalse(self.boss.confirm.call_args.kwargs['confirm_on_accept'])
        self.assertFalse(self.boss.confirm.call_args.kwargs['confirm_on_cancel'])

    def test_confirmed_image_targets_original_pane(self):
        with patch.dict(GLOBALS, _clipboard_image_path=lambda: '/tmp/image.png'):
            self.invoke(True)
            self.boss.active_window = Mock()
            self.boss.confirm.call_args.args[1](True)
        self.window.paste_text.assert_called_once_with('/tmp/image.png')
        self.boss.active_window.paste_text.assert_not_called()

    def test_confirmed_text(self):
        with patch.dict(GLOBALS, _clipboard_image_path=lambda: None), \
                patch('kitty.clipboard.get_clipboard_string', return_value='text'):
            self.invoke(True)
            self.boss.confirm.call_args.args[1](True)
        self.window.paste_text.assert_called_once_with('text')

    def test_closed_pane_is_not_pasted_into(self):
        self.invoke(True)
        self.boss.window_id_map.clear()
        self.boss.confirm.call_args.args[1](True)
        self.window.paste_text.assert_not_called()

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
