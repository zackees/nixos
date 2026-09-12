"""Policy regressions; synthetic procfs never reads the user's environment."""
import json
from pathlib import Path
import tempfile
import time
import unittest

from resolver import Resolver


class ResolveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.proc = root / "proc"
        self.runtime = root / "runtime"
        self.proc.mkdir()
        self.runtime.mkdir()
        self.resolver = Resolver(self.proc, self.runtime)
        self.windows = [dict(id="terminal-a", pid=100, caption="project-a"),
                        dict(id="terminal-b", pid=100, caption="project-b")]
        self.process(100, 1)
        self.process(110, 100, KITTY_PID="100", KITTY_WINDOW_ID="2")
        self.process(120, 110)

    def process(self, pid, parent, **env):
        directory = self.proc / str(pid)
        directory.mkdir(exist_ok=True)
        # stat field 22 is starttime; comm may contain spaces and parentheses.
        (directory / "stat").write_text(
            f"{pid} (test (process)) S {parent} " + "0 " * 17 + "12345 0\n")
        (directory / "environ").write_bytes(
            b"\0".join(f"{k}={v}".encode() for k, v in env.items()))

    def snapshot(self, **overrides):
        data = dict(start="12345", time=time.monotonic(), windows=[
            dict(title="project-a", panes=[1]), dict(title="project-b", panes=[2])])
        data.update(overrides)
        (self.runtime / "kitty-launch-origin-100.json").write_text(json.dumps(data))

    def test_delayed_child_uses_parent_not_current_desktop(self):
        self.assertEqual(self.resolver.resolve(120, self.windows[:1]), "terminal-a")

    def test_shared_kitty_process_uses_originating_pane(self):
        self.snapshot()
        self.assertEqual(self.resolver.resolve(120, self.windows), "terminal-b")

    def test_ambiguous_process_without_metadata_is_not_guessed(self):
        self.assertEqual(self.resolver.resolve(120, self.windows), "")

    def test_identical_terminal_titles_are_not_guessed(self):
        self.snapshot(windows=[dict(title="same", panes=[1]), dict(title="same", panes=[2])])
        self.windows[0]["caption"] = "same"
        self.windows[1]["caption"] = "same"
        self.assertEqual(self.resolver.resolve(120, self.windows), "")

    def test_stale_snapshot_is_ignored(self):
        self.snapshot(time=time.monotonic() - 30)
        self.assertEqual(self.resolver.resolve(120, self.windows), "")

    def test_metadata_title_collision_during_title_change_is_not_guessed(self):
        self.snapshot(windows=[dict(title="project-a", panes=[1]),
                               dict(title="project-a", panes=[2])])
        self.assertEqual(self.resolver.resolve(120, self.windows), "")

    def test_reused_kitty_pid_is_ignored(self):
        self.snapshot(start="999")
        self.assertEqual(self.resolver.resolve(120, self.windows), "")

    def test_exited_process_is_ignored(self):
        self.assertEqual(self.resolver.resolve(999, self.windows), "")

    def test_same_process_new_window_does_not_inherit_arbitrary_sibling(self):
        self.assertEqual(self.resolver.resolve(100, self.windows), "")

    def test_nearest_parent_wins_over_inherited_kitty_environment(self):
        self.snapshot()
        self.process(120, 110, KITTY_PID="100", KITTY_WINDOW_ID="1")
        self.windows.append(dict(id="intermediate-app", pid=110, caption="app"))
        self.assertEqual(self.resolver.resolve(120, self.windows), "intermediate-app")

    def test_detached_child_can_use_inherited_pane_identity(self):
        self.snapshot()
        self.process(120, 1, KITTY_PID="100", KITTY_WINDOW_ID="2")
        self.assertEqual(self.resolver.resolve(120, self.windows), "terminal-b")


if __name__ == "__main__":
    unittest.main()
