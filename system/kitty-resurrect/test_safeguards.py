"""Tests for safeguards.py, one class per safeguard.

    python3 -m unittest system/kitty-resurrect/test_safeguards.py

Also run by the kitty-resurrect derivation, so a failure fails the rebuild.
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import safeguards as sg  # noqa: E402


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.path = self.dir / "guard.json"
        self.logs = []

    def tearDown(self):
        self.tmp.cleanup()

    def ledger(self, session="boot:3"):
        led = sg.Ledger(self.path, log=self.logs.append)
        led.begin_session(session)
        return led


class AttemptCapAndBackoff(Base):
    def test_delay_doubles_and_is_capped(self):
        self.assertEqual([sg.backoff(n) for n in (1, 2, 3, 4)], [5, 10, 20, 40])
        self.assertEqual(sg.backoff(30), sg.MAX_DELAY)

    def test_attempts_stop_at_the_cap(self):
        led = self.ledger()
        for n in range(1, sg.MAX_ATTEMPTS + 1):
            d = led.gate(now=1000 + n)
            self.assertTrue(d.allowed, d)
            self.assertEqual(d.attempt, n)
            led.start(now=1000 + n)
            led.finish("ok", now=1000 + n)
        d = led.gate(now=2000)
        self.assertFalse(d.allowed)
        self.assertEqual(d.reason, "attempt-cap")

    def test_cap_survives_a_service_restart(self):
        led = self.ledger()
        for _ in range(sg.MAX_ATTEMPTS):
            led.start(now=1)
            led.finish("skipped", now=1)
        self.assertEqual(self.ledger().gate(now=2).reason, "attempt-cap")


class CircuitBreaker(Base):
    def test_failures_in_window_open_the_breaker_and_log_once(self):
        led = self.ledger()
        for t in (100, 200, 300):
            led.start(now=t)
            led.finish("failed", now=t)
        self.assertTrue(led.breaker_open)
        self.assertEqual(sum("breaker open" in m for m in self.logs), 1)
        d = led.gate(now=400)
        self.assertFalse(d.allowed)
        self.assertEqual(d.reason, "breaker-open")
        # Persisted: a restarted service stays down too.
        self.assertTrue(self.ledger().breaker_open)

    def test_failures_spread_beyond_the_window_do_not_open_it(self):
        led = self.ledger()
        for t in (0, sg.WINDOW + 1):
            led.start(now=t)
            led.finish("failed", now=t)
        self.assertFalse(led.breaker_open)

    def test_attempt_in_flight_at_service_death_counts_as_failed(self):
        for t in (10, 20, 30):
            led = self.ledger()
            led.start(now=t)   # service dies before finish()
        led = self.ledger()
        led.gate(now=40)
        self.assertTrue(led.breaker_open)

    def test_new_login_session_closes_it(self):
        led = self.ledger()
        for t in (1, 2, 3):
            led.start(now=t)
            led.finish("failed", now=t)
        self.assertTrue(led.breaker_open)
        led = self.ledger(session="boot:4")
        self.assertFalse(led.breaker_open)
        self.assertTrue(led.gate(now=5).allowed)

    def test_operator_reset_closes_it(self):
        led = self.ledger()
        for t in (1, 2, 3):
            led.start(now=t)
            led.finish("failed", now=t)
        led.reset()
        self.assertFalse(self.ledger().breaker_open)
        self.assertTrue(self.ledger().gate(now=5).allowed)

    def test_corrupt_ledger_is_treated_as_empty(self):
        self.path.write_text("{not json")
        self.assertTrue(self.ledger().gate(now=1).allowed)


class OutputStability(Base):
    good = [{"name": "DP-1", "width": 2560, "height": 1440}]

    def test_healthy(self):
        self.assertIsNone(sg.outputs_unhealthy(self.good, True, changed=0, now=100))

    def test_inactive_session(self):
        self.assertEqual(sg.outputs_unhealthy(self.good, False, 0, 100), "session-inactive")

    def test_unknown_session_state_is_not_healthy(self):
        self.assertEqual(sg.outputs_unhealthy(self.good, None, 0, 100), "session-inactive")

    def test_no_report_from_kwin(self):
        self.assertEqual(sg.outputs_unhealthy(None, True, 0, 100), "no-output-report")
        self.assertEqual(sg.outputs_unhealthy([], True, 0, 100), "no-outputs")

    def test_zero_geometry(self):
        bad = [{"name": "DP-1", "width": 0, "height": 0}]
        self.assertEqual(sg.outputs_unhealthy(bad, True, 0, 100), "output-degraded")

    def test_recent_change(self):
        self.assertEqual(sg.outputs_unhealthy(self.good, True, changed=95, now=100), "outputs-settling")


class KillSwitch(Base):
    def test_off_by_default(self):
        self.assertIsNone(sg.disabled({}, self.dir / "disabled"))

    def test_file(self):
        (self.dir / "disabled").touch()
        self.assertEqual(sg.disabled({}, self.dir / "disabled"), "kill-switch-file")

    def test_env(self):
        self.assertEqual(sg.disabled({"KITTY_RESURRECT_DISABLE": "1"}, self.dir / "x"), "kill-switch-env")
        self.assertIsNone(sg.disabled({"KITTY_RESURRECT_DISABLE": "0"}, self.dir / "x"))


class SelfObservation(Base):
    def test_one_greppable_line(self):
        line = sg.summary(2, 3, "skipped", "session-inactive", 10)
        self.assertEqual(line, "kitty-resurrect: attempt 2/3 outcome=skipped reason=session-inactive next=10s")
        self.assertNotIn("\n", line)

    def test_no_next(self):
        self.assertEqual(sg.summary(3, 3, "failed", "unclaimed", None),
                         "kitty-resurrect: attempt 3/3 outcome=failed reason=unclaimed next=none")

    def test_ledger_writes_valid_json(self):
        led = self.ledger()
        led.start(now=1)
        self.assertEqual(json.loads(self.path.read_text())["attempts"][0]["outcome"], "started")


if __name__ == "__main__":
    unittest.main()
