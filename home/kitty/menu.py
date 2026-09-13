"""Compatibility entry point for older right-click mappings."""
from kittens.tui.handler import result_handler


def main(args):
    raise SystemExit('Use this kitten from a kitty.conf mapping')


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    window = boss.window_id_map.get(target_window_id)
    if window is not None:
        boss.run_kitten_with_metadata('paste.py', ['--confirm'], window=window)
