"""Tests for watchdog.py: classification, the ladder's decision table,
breaker interaction and dry-run. See docs/kitty-resurrect-watchdog.md.

Also run by the kitty-resurrect derivation, so a failure fails the rebuild.
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import safeguards as sg  # noqa: E402
import watchdog as wd  # noqa: E402

# Verbatim from journalctl --user -u plasma-kwin_wayland, 2026-10-31.
INCIDENT = """\
Failed to find a working output layer configuration!
Applying output configuration failed!
atomic commit failed: Permission denied
"""
BENIGN = """\
kwin_xwayland: XWayland started
Could not find the desktop file for org.kde.foo
"""


class Classify(unittest.TestCase):
    def test_inactive_session_wins(self):
        self.assertEqual(wd.classify(False, ""), "session-inactive")

    def test_unknown_session_is_never_acted_on(self):
        self.assertEqual(wd.classify(None, INCIDENT), "unknown")

    def test_incident_journal(self):
        self.assertEqual(wd.classify(True, INCIDENT), "output-errors")
        for line in INCIDENT.splitlines():
            self.assertEqual(wd.classify(True, line), "output-errors", line)

    def test_benign_journal(self):
        self.assertEqual(wd.classify(True, BENIGN), "ok")
        self.assertEqual(wd.classify(True, ""), "ok")

    def test_luminance_only_as_last_resort(self):
        self.assertEqual(wd.classify(True, "", luma=0.001), "dark-frame")
        self.assertEqual(wd.classify(True, "", luma=0.4), "ok")
        self.assertEqual(wd.classify(False, "", luma=0.4), "session-inactive")


class DecisionTable(unittest.TestCase):
    def d(self, signal, off=None, breaker=False, cap=False, active=True):
        return wd.decide(signal, disabled=off, breaker_open=breaker,
                         cap_reached=cap, session_active=active)

    def test_rows(self):
        rows = [
            (dict(signal="session-inactive", off="kill-switch-file"), (None, "kill-switch-file")),
            (dict(signal="session-inactive", breaker=True), (None, "breaker-open")),
            (dict(signal="session-inactive", cap=True), (None, "attempt-cap")),
            (dict(signal="ok"), (None, "healthy")),
            (dict(signal="unknown"), (None, "unknown")),
            (dict(signal="session-inactive", active=False), ("activate", "session-inactive")),
            (dict(signal="output-errors"), ("reload-script", "output-errors")),
            (dict(signal="dark-frame"), ("reload-script", "dark-frame")),
            (dict(signal="output-errors", active=False), ("activate", "output-errors")),
        ]
        for kw, want in rows:
            self.assertEqual(self.d(**kw), want, kw)


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.logs, self.actions = [], []
        self.state = {"active": True, "journal": ""}
        self.env = {}

    def tearDown(self):
        self.tmp.cleanup()

    def dog(self, dry_run=False):
        ledger = sg.Ledger(self.dir / "watchdog.json", log=self.logs.append)
        ledger.begin_session("boot:3")
        return wd.Watchdog(
            ledger,
            probe=lambda since: (self.state["active"], self.state["journal"]),
            actions={"activate": lambda: self.actions.append("activate"),
                     "reload-script": lambda: self.actions.append("reload-script")},
            disabled=lambda: sg.disabled(self.env, self.dir / "disabled"),
            log=self.logs.append, dry_run=dry_run)


class Ladder(Harness):
    def test_recovers_and_records_ok(self):
        dog = self.dog()
        self.state["active"] = False
        dog.tick(100)
        self.assertEqual(self.actions, ["activate"])
        self.state["active"] = True
        dog.tick(115)
        self.assertEqual(dog.ledger.attempts[-1]["outcome"], "ok")
        self.assertTrue(any("attempt 1/3 signal=session-inactive action=activate outcome=started"
                            in line for line in self.logs), self.logs)
        self.assertTrue(any("outcome=ok" in line for line in self.logs))

    def test_climbs_to_reload_when_active_but_outputs_broken(self):
        dog = self.dog()
        self.state.update(active=False, journal=INCIDENT)
        dog.tick(100)
        self.state["active"] = True   # activate worked, outputs still failing
        dog.tick(115)
        self.assertEqual(self.actions, ["activate", "reload-script"])
        self.assertEqual(dog.ledger.attempts[0]["outcome"], "failed")

    def test_still_black_opens_breaker_and_stops(self):
        dog = self.dog()
        self.state["active"] = False
        for t in range(100, 400, 15):
            dog.tick(t)
        self.assertEqual(len(self.actions), sg.BREAKER_FAILURES)
        self.assertTrue(dog.ledger.breaker_open)
        self.assertEqual(sum("breaker open" in line for line in self.logs), 1)

    def test_breaker_open_means_no_action(self):
        dog = self.dog()
        dog.ledger.breaker = {"since": 0, "failures": 3}
        self.state["active"] = False
        dog.tick(100)
        dog.tick(115)
        self.assertEqual(self.actions, [])

    def test_kill_switch_means_no_action(self):
        self.env[sg.KILL_ENV] = "1"
        dog = self.dog()
        self.state["active"] = False
        dog.tick(100)
        self.assertEqual(self.actions, [])

    def test_separate_incidents_expire(self):
        dog = self.dog()
        for start in (100, 2000, 4000, 6000):
            self.state["active"] = False
            dog.tick(start)
            self.state["active"] = True
            dog.tick(start + 15)
        self.assertEqual(self.actions, ["activate"] * 4)
        self.assertFalse(dog.ledger.breaker_open)

    def test_ledger_survives_restart(self):
        self.state["active"] = False
        self.dog().tick(100)          # dies with the attempt in flight
        dog = self.dog()
        self.assertEqual(dog.ledger.attempts[0]["outcome"], "failed")


class DryRun(Harness):
    def test_dry_run_performs_nothing(self):
        dog = self.dog(dry_run=True)
        self.state.update(active=False, journal=INCIDENT)
        for t in range(100, 400, 15):
            dog.tick(t)
        self.assertEqual(self.actions, [])
        self.assertTrue(any("dry-run" in line for line in self.logs))
        # still exercises the whole ladder, breaker included
        self.assertTrue(dog.ledger.breaker_open)


if __name__ == "__main__":
    unittest.main()
