# /// script
# requires-python = ">=3.12"
# dependencies = ["dbus-fast==2.44.1"]
# ///
"""KRunner plugin behind Meta+Space: go/* links and the tiling editor.

KRunner draws the popup and owns the keyboard; this answers its D-Bus
Match/Run calls (the org.kde.krunner1 interface, as KWin's own window runner
does). Two kinds of result:

  go/<name>   open http://go/<name> in a NEW browser window, so it lands on
              the current desktop instead of in a tab of a window elsewhere.
  tile...     KWin's tiles editor -- the same thing Meta+T opens.
"""

import asyncio
import subprocess

from dbus_fast import Variant
from dbus_fast.aio import MessageBus
from dbus_fast.service import ServiceInterface, method

SERVICE = "org.niteris.GoRunner"
PATH = "/runner"
TILE_WORDS = ("tile", "tiles", "tiling", "layout")


def go_url(query):
    q = query.strip()
    for prefix in ("http://", "https://"):
        if q.startswith(prefix):
            q = q[len(prefix):]
    if q.startswith("go/") and len(q) > 3:
        return "http://" + q
    return None


class Runner(ServiceInterface):
    def __init__(self):
        super().__init__("org.kde.krunner1")

    @method()
    def Match(self, query: "s") -> "a(sssida{sv})":
        out = []
        if url := go_url(query):
            out.append([url, "Open " + url[len("http://"):], "internet-web-browser",
                        100, 1.0, {"subtext": Variant("s", "new browser window")}])
        q = query.strip().lower()
        if len(q) >= 3 and any(w.startswith(q) or q.startswith(w) for w in TILE_WORDS):
            out.append(["tiles", "Tiling editor", "view-grid", 100, 0.9,
                        {"subtext": Variant("s", "Meta+T")}])
        return out

    @method()
    def Actions(self) -> "a(sss)":
        return []

    @method()
    def Run(self, match_id: "s", action_id: "s"):
        if match_id == "tiles":
            cmd = ["qdbus", "org.kde.kglobalaccel", "/component/kwin",
                   "org.kde.kglobalaccel.Component.invokeShortcut", "Edit Tiles"]
        else:
            cmd = ["brave", "--new-window", match_id]
        subprocess.Popen(cmd, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


async def main():
    bus = await MessageBus().connect()
    bus.export(PATH, Runner())
    await bus.request_name(SERVICE)
    await bus.wait_for_disconnect()


if __name__ == "__main__":
    asyncio.run(main())
