# Custom tab bar: stock powerline tabs, plus a permanent reminder on the
# right telling you where the cheat sheet and the command palette live.
from kitty.tab_bar import as_rgb, draw_tab_with_powerline

KEY = 0xfdbc4b   # amber, matches color11
LBL = 0x7f8c8d   # Breeze inactive-tab grey

# (text, colour) segments, drawn right-aligned after the last tab
HINT = (
    ('  Super+/ ', KEY), ('keys', LBL),
    ('   Ctrl+Shift+M ', KEY), ('menu  ', LBL),
)
HINT_LEN = sum(len(t) for t, _ in HINT)


def draw_tab(draw_data, screen, tab, before, max_tab_length, index, is_last,
             extra_data):
    end = draw_tab_with_powerline(
        draw_data, screen, tab, before, max_tab_length, index, is_last,
        extra_data)
    # for_layout passes measure tab widths via cursor.x - never draw then.
    if is_last and not extra_data.for_layout:
        start = screen.columns - HINT_LEN
        if start > screen.cursor.x + 1:
            screen.cursor.x = start
            screen.cursor.bg = as_rgb(int(draw_data.default_bg))
            screen.cursor.bold = screen.cursor.italic = False
            for text, colour in HINT:
                screen.cursor.fg = as_rgb(colour)
                screen.draw(text)
    return end
