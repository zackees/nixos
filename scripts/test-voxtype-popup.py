import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "popup", Path(__file__).resolve().parents[1] / "system/voxtype-popup.py"
)
popup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(popup)


class ArgumentsTests(unittest.TestCase):
    def test_voxtype_status_arguments(self):
        message, print_id = popup.arguments([
            "--app-name=Voxtype", "--urgency=normal", "--expire-time=2000",
            "-h", "string:x-canonical-private-synchronous:voxtype",
            "-h", "int:transient:1", "Voxtype (Parakeet)", "Recording…",
        ])
        self.assertEqual(message, {"title": "Voxtype (Parakeet)",
                                  "body": "Recording…", "timeout": 2000})
        self.assertFalse(print_id)

    def test_persistent_recording_and_replacement_id(self):
        message, print_id = popup.arguments([
            "-p", "-r", "1", "-t", "0", "Voxtype", "Recording",
        ])
        self.assertEqual(message["timeout"], 0)
        self.assertTrue(print_id)

    def test_transcription_remains_plain_text(self):
        text = '<b>Literal text</b> & "quotes"\nSecond line ☕'
        message, _ = popup.arguments(["Voxtype", text])
        self.assertEqual(message["body"], text)


if __name__ == "__main__":
    unittest.main()
