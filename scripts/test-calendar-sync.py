"""Run with the Python interpreter from calendar-sync.service's ExecStart."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock
from datetime import datetime, timedelta, timezone

from icalendar import Calendar

spec = importlib.util.spec_from_file_location(
    "calendar_sync", Path(__file__).resolve().parents[1] / "system/calendar-sync.py"
)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def event(**overrides):
    return {
        "id": "instance-1", "summary": "A meeting, with Unicode ☕",
        "updated": "2026-10-21T10:00:00Z",
        "start": {"dateTime": "2026-11-02T10:00:00-08:00"},
        "end": {"dateTime": "2026-11-02T11:00:00-08:00"},
        **overrides,
    }


class CalendarSyncTests(unittest.TestCase):
    def test_resource_detection_handles_kconfig_home_expansion(self):
        path = Path.home() / ".local/share/calendar-sync/google.ics"
        for value in (str(path), path.as_uri(),
                      "file:$HOME/.local/share/calendar-sync/google.ics"):
            self.assertTrue(sync.resource_matches("[General]\nPath[$e]=" + value, path))
        self.assertFalse(sync.resource_matches("Path=/other/calendar.ics", path))

    def events(self, items):
        return Calendar.from_ical(sync.calendar_bytes(items)).walk("VEVENT")

    def test_reminders_and_timezone_survive_serialization(self):
        e = self.events([event()])[0]
        self.assertEqual(e.decoded("dtstart").astimezone(timezone.utc).hour, 18)
        self.assertIn(b"DTSTART:20261102T180000Z", sync.calendar_bytes([event()]))
        self.assertEqual(str(e["summary"]), "A meeting, with Unicode ☕")
        self.assertEqual([a.decoded("trigger") for a in e.walk("VALARM")],
                         [-timedelta(minutes=10), timedelta(0)])

    def test_all_day_events_have_no_midnight_reminder(self):
        e = self.events([event(start={"date": "2026-11-02"},
                               end={"date": "2026-11-03"})])[0]
        self.assertEqual(e.walk("VALARM"), [])

    def test_cancelled_and_declined_events_disappear(self):
        self.assertEqual(self.events([
            event(status="cancelled"),
            event(attendees=[{"self": True, "responseStatus": "declined"}]),
        ]), [])
        self.assertEqual(len(self.events([event(attendees=[
            {"self": False, "responseStatus": "declined"}
        ])])), 1)

    def test_repeated_sync_is_stable_and_preserves_instance_ids(self):
        items = [event(id="recurrence-2"), event(id="recurrence-1")]
        self.assertEqual(sync.calendar_bytes(items), sync.calendar_bytes(items[::-1]))
        self.assertEqual(len({str(e["uid"]) for e in self.events(items)}), 2)

    def test_paginated_fetch_includes_hidden_invitations(self):
        session = Mock()
        first, second = Mock(), Mock()
        first.json.return_value = {"items": [event()], "nextPageToken": "next"}
        second.json.return_value = {"items": [event(id="second")]}
        session.get.side_effect = [first, second]
        result = sync.fetch(session, "calendar@example.com", datetime.now(timezone.utc))
        self.assertEqual(len(result), 2)
        self.assertEqual(session.get.call_count, 2)
        params = session.get.call_args.kwargs["params"]
        self.assertEqual(params["showHiddenInvitations"], "true")
        self.assertEqual(params["pageToken"], "next")

    def test_api_failure_does_not_return_partial_calendar(self):
        session = Mock()
        session.get.return_value.raise_for_status.side_effect = RuntimeError("offline")
        with self.assertRaises(RuntimeError):
            sync.fetch(session, "calendar@example.com", datetime.now(timezone.utc))


if __name__ == "__main__":
    unittest.main()
