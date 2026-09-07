#!/usr/bin/env python3
"""A right-click menu for kitty: Copy / Paste / Paste selection.

kitty draws no menus of its own; the command palette is the only stock
popup and it is a full-window list of every action. This kitten is the
compact alternative: a three-line overlay at the top-left of the window,
driven by mouse click, arrow keys + Enter, or the first letter. Esc, q or
a click outside the items closes it. Bound in kitty.conf with

    mouse_map right press ungrabbed kitten menu.py

so it only appears in windows whose program has not grabbed the mouse; a
grabbed program (Claude Code, vim with mouse on) gets the right-click.
"""
from kittens.tui.handler import Handler, result_handler
from kittens.tui.loop import Loop
from kittens.tui.operations import MouseTracking, styled

ITEMS = (
    ('c', 'Copy', 'copy'),
    ('v', 'Paste', 'paste'),
    ('s', 'Paste selection', 'paste_selection'),
)


class Menu(Handler):
    mouse_tracking = MouseTracking.buttons_only

    def __init__(self) -> None:
        self.selected = 0
        self.answer = None

    def initialize(self) -> None:
        self.cmd.set_cursor_visible(False)
        self.draw_screen()

    def draw_screen(self) -> None:
        self.cmd.clear_screen()
        width = max(len(label) for _, label, _ in ITEMS) + 6
        for i, (key, label, _) in enumerate(ITEMS):
            line = f' {key}  {label}'.ljust(width)
            self.print(styled(line, reverse=True) if i == self.selected else styled(line, dim=False))
        self.print(styled(' esc closes'.ljust(width), dim=True))

    def on_resize(self, new_size) -> None:
        self.draw_screen()

    def choose(self, index: int) -> None:
        self.answer = ITEMS[index][2]
        self.quit_loop(0)

    def on_key(self, key_event) -> None:
        if key_event.matches('esc') or key_event.matches('q'):
            self.quit_loop(1)
        elif key_event.matches('up') or key_event.matches('k'):
            self.selected = (self.selected - 1) % len(ITEMS)
            self.draw_screen()
        elif key_event.matches('down') or key_event.matches('j'):
            self.selected = (self.selected + 1) % len(ITEMS)
            self.draw_screen()
        elif key_event.matches('enter'):
            self.choose(self.selected)

    def on_text(self, text: str, in_bracketed_paste: bool = False) -> None:
        for i, (key, _, _) in enumerate(ITEMS):
            if text.lower() == key:
                self.choose(i)
                return
        if text.lower() == 'q':
            self.quit_loop(1)

    def on_click(self, mouse_event) -> None:
        if mouse_event.cell_y < len(ITEMS):
            self.choose(mouse_event.cell_y)
        else:
            self.quit_loop(1)

    def on_interrupt(self) -> None:
        self.quit_loop(1)

    def on_eot(self) -> None:
        self.quit_loop(1)


def main(args):
    handler = Menu()
    loop = Loop()
    loop.loop(handler)
    return handler.answer


@result_handler()
def handle_result(args, answer, target_window_id, boss):
    # Runs inside kitty once the overlay has closed. The selection belongs
    # to the underlying window and survives the overlay, so Copy still has
    # something to copy.
    w = boss.window_id_map.get(target_window_id)
    if w is None or not answer:
        return
    if answer == 'copy':
        w.copy_to_clipboard()
    elif answer == 'paste':
        from kitty.fast_data_types import get_clipboard_string
        w.paste_text(get_clipboard_string())
    elif answer == 'paste_selection':
        w.paste_selection()
