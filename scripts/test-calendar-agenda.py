#!/usr/bin/env python3
"""Date boundaries and selection rules for the panel's private calendar feed."""
import importlib.util
import os
from pathlib import Path
import time
import unittest
from datetime import datetime, timezone

from icalendar import Calendar

spec = importlib.util.spec_from_file_location("agenda", Path(__file__).resolve().parents[1] / "system/calendar-agenda.py")
agenda = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agenda)


def calendar(*events):
    body = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + "".join(
        "BEGIN:VEVENT\r\n" + event.replace("\n", "\r\n") + "\r\nEND:VEVENT\r\n" for event in events
    ) + "END:VCALENDAR\r\n"
    return Calendar.from_ical(body)


class AgendaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old_tz = os.environ.get("TZ")
        os.environ["TZ"] = "America/Los_Angeles"
        time.tzset()

    @classmethod
    def tearDownClass(cls):
        if cls.old_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = cls.old_tz
        time.tzset()

    def test_ongoing_beats_future_and_past_remains_in_day(self):
        data = agenda.today_agenda(calendar(
            "DTSTART:20261022T160000Z\nDTEND:20261022T170000Z\nSUMMARY:Finished",
            "DTSTART:20261022T170000Z\nDTEND:20261022T180000Z\nSUMMARY:Current",
            "DTSTART:20261022T180000Z\nDTEND:20261022T190000Z\nSUMMARY:Next",
            "DTSTART:20261022T190000Z\nDTEND:20261022T200000Z\nSUMMARY:Cancelled\nSTATUS:CANCELLED",
        ), datetime(2026, 10, 22, 17, 30, tzinfo=timezone.utc))
        self.assertEqual([row["status"] for row in data["events"]], ["past", "current", "upcoming"])
        self.assertEqual(data["next"]["title"], "Current")
        self.assertEqual(data["nextLabel"], "Now")

    def test_joinable_meeting_wins_same_start_time(self):
        data = agenda.today_agenda(calendar(
            "DTSTART:20261022T170000Z\nDTEND:20261022T190000Z\nSUMMARY:Calendar block",
            "DTSTART:20261022T170000Z\nDTEND:20261022T180000Z\nSUMMARY:Call\nLOCATION:https://example.zoom.us/j/123",
        ), datetime(2026, 10, 22, 16, tzinfo=timezone.utc))
        self.assertEqual(data["next"]["title"], "Call")
        self.assertEqual(len(data["events"]), 2)

    def test_local_day_and_exclusive_all_day_end(self):
        data = agenda.today_agenda(calendar(
            "DTSTART:20261023T013000Z\nDTEND:20261023T020000Z\nSUMMARY:Tonight",
            "DTSTART:20261023T080000Z\nDTEND:20261023T090000Z\nSUMMARY:Tomorrow",
            "DTSTART;VALUE=DATE:20261021\nDTEND;VALUE=DATE:20261022\nSUMMARY:Ended yesterday",
            "DTSTART;VALUE=DATE:20261022\nDTEND;VALUE=DATE:20261023\nSUMMARY:All day",
        ), datetime(2026, 10, 22, 17, tzinfo=timezone.utc))
        self.assertEqual([row["title"] for row in data["events"]], ["All day", "Tonight"])
        self.assertEqual(data["next"]["title"], "Tonight")
        self.assertEqual(data["nextLabel"], "6:30 PM")

    def test_overnight_and_dst_boundary(self):
        data = agenda.today_agenda(calendar(
            "DTSTART:20261101T063000Z\nDTEND:20261101T083000Z\nSUMMARY:Overnight",
            "DTSTART:20261102T073000Z\nDTEND:20261102T080000Z\nSUMMARY:Late tonight",
        ), datetime(2026, 11, 1, 8, tzinfo=timezone.utc))
        self.assertEqual(len(data["events"]), 2)
        self.assertEqual(data["next"]["title"], "Overnight")
        self.assertTrue(data["events"][0]["time"].startswith("Yesterday"))

    def test_zoom_domain_validation_and_safe_fallback(self):
        event = calendar("DTSTART;VALUE=DATE:20261022\nDESCRIPTION:https://zoom.us.evil.test/j/123 https://example.zoom.us/j/456\nSUMMARY:Meeting").walk("VEVENT")[0]
        self.assertEqual(agenda.event_link(event), ("https://example.zoom.us/j/456", "Zoom"))
        event["DESCRIPTION"] = "https://zoom.us.evil.test/j/123"
        event["URL"] = "javascript:alert(1)"
        self.assertEqual(agenda.event_link(event), ("", ""))


if __name__ == "__main__":
    unittest.main()
