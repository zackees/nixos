"""Google parsing, serialization and notification rules for calendar-sync."""

import json
import unittest
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from unittest.mock import patch

import calendar_json
import calendar_sync
from calendar_ical import parse_events
from calendar_json import JsonError
from calendar_sync import GoogleEvent, SeenState


def google(**overrides: object) -> GoogleEvent:
    """Parse a Google API event, with sensible defaults."""
    fields: dict[str, object] = {
        "id": "instance-1",
        "summary": "A meeting, with Unicode ☕",
        "updated": "2026-10-21T10:00:00Z",
        "start": {"dateTime": "2026-11-02T10:00:00-08:00"},
        "end": {"dateTime": "2026-11-02T11:00:00-08:00"},
        **overrides,
    }
    return GoogleEvent.parse(calendar_json.parse(json.dumps(fields)))


class FakeNotifier:
    """Records notifications instead of talking to D-Bus."""

    owner: str = ":1.42"

    def __init__(self) -> None:
        """Start with nothing shown."""
        self.shown: list[tuple[str, str]] = []
        self.closed: list[int] = []

    def notify(self, summary: str, body: str) -> int:
        """Record a notification."""
        self.shown.append((summary, body))
        return 123

    def close(self, notification_id: int) -> None:
        """Record a close."""
        self.closed.append(notification_id)


class FakeResponse:
    """A canned HTTP response."""

    def __init__(self, body: object, *, fail: bool = False) -> None:
        """Hold the JSON body to return."""
        self.text: str = json.dumps(body)
        self._fail: bool = fail

    def raise_for_status(self) -> None:
        """Raise like requests does for an HTTP error."""
        if self._fail:
            msg = "offline"
            raise RuntimeError(msg)


class FakeSession:
    """Serves canned pages and records the parameters it was asked for."""

    def __init__(self, *responses: FakeResponse) -> None:
        """Queue the responses."""
        self.responses: list[FakeResponse] = list(responses)
        self.params: list[dict[str, str]] = []

    def get(self, url: str, *, params: dict[str, str], timeout: int) -> FakeResponse:
        """Return the next canned response."""
        del url, timeout
        self.params.append(dict(params))
        return self.responses.pop(0)


NOW = datetime(2026, 10, 22, 12, tzinfo=UTC)


class ParsingTests(unittest.TestCase):
    def test_wrong_types_are_rejected_on_entry(self) -> None:
        with self.assertRaises(JsonError):
            _ = google(summary=7)
        with self.assertRaises(JsonError):
            _ = google(attendees="nobody")
        with self.assertRaises(JsonError):
            _ = calendar_json.parse("[]")

    def test_all_day_and_timed_starts(self) -> None:
        self.assertEqual(google(start={"date": "2026-11-02"}).start, date(2026, 11, 2))
        self.assertEqual(google().start, datetime(2026, 11, 2, 18, tzinfo=UTC))

    def test_seen_state_round_trips(self) -> None:
        state = SeenState(frozenset({"b", "a"}), NOW)
        self.assertEqual(SeenState.parse(calendar_json.parse(state.to_json())), state)


class NotificationTests(unittest.TestCase):
    def test_invitation_popup_escapes_markup(self) -> None:
        notifier = FakeNotifier()
        event = google(
            summary="Meeting <test>", attendees=[{"self": True, "responseStatus": "needsAction"}]
        )
        with patch.object(calendar_sync, "schedule_close"):
            calendar_sync.notify(event, notifier)
        [(summary, body)] = notifier.shown
        self.assertEqual(summary, "New calendar invitation")
        self.assertIn("Meeting &lt;test&gt;", body)

    def test_expiry_targets_the_original_server_instance(self) -> None:
        command = calendar_sync.close_command(":1.42", 123, 4599)
        self.assertIn("--on-calendar=@4599", command)
        self.assertEqual(
            command[-6:],
            [
                ":1.42",
                "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications",
                "CloseNotification",
                "u",
                "123",
            ],
        )

    def test_timer_failure_closes_popup_immediately(self) -> None:
        notifier = FakeNotifier()
        with (
            patch.object(calendar_sync, "schedule_close", side_effect=RuntimeError("timer")),
            self.assertRaises(RuntimeError),
        ):
            calendar_sync.notify(google(), notifier)
        self.assertEqual(notifier.closed, [123])

    def test_first_sync_is_quiet_and_later_ones_announce_new_events(self) -> None:
        events = [google(id="old"), google(id="new")]
        self.assertEqual(calendar_sync.announce(events, None, NOW), [])
        previous = SeenState(frozenset({"old"}), NOW + timedelta(days=90))
        self.assertEqual([e.id for e in calendar_sync.announce(events, previous, NOW)], ["new"])
        past = [google(id="past", start={"dateTime": "2026-10-01T10:00:00Z"})]
        self.assertEqual(calendar_sync.announce(past, previous, NOW), [])


class SerializationTests(unittest.TestCase):
    def test_resource_detection_handles_kconfig_home_expansion(self) -> None:
        path = Path.home() / ".local/share/calendar-sync/google.ics"
        for value in (str(path), path.as_uri(), "file:$HOME/.local/share/calendar-sync/google.ics"):
            self.assertTrue(calendar_sync.resource_matches("[General]\nPath[$e]=" + value, path))
        self.assertFalse(calendar_sync.resource_matches("Path=/other/calendar.ics", path))

    def test_utc_start_summary_and_reminders_survive(self) -> None:
        data = calendar_sync.calendar_bytes([google()])
        self.assertIn(b"DTSTART:20261102T180000Z", data)
        self.assertIn(b"TRIGGER:-PT10M", data)
        [event] = parse_events(data)
        self.assertEqual(event.summary, "A meeting, with Unicode ☕")

    def test_all_day_events_have_no_midnight_reminder(self) -> None:
        data = calendar_sync.calendar_bytes(
            [google(start={"date": "2026-11-02"}, end={"date": "2026-11-03"})]
        )
        self.assertNotIn(b"VALARM", data)

    def test_block_markers_reach_the_agenda(self) -> None:
        data = calendar_sync.calendar_bytes(
            [google(transparency="transparent", eventType="focusTime")]
        )
        [event] = parse_events(data)
        self.assertTrue(event.transparent)
        self.assertEqual(event.event_type, "focusTime")

    def test_cancelled_and_declined_events_disappear(self) -> None:
        self.assertEqual(
            parse_events(
                calendar_sync.calendar_bytes(
                    [
                        google(status="cancelled"),
                        google(attendees=[{"self": True, "responseStatus": "declined"}]),
                    ]
                )
            ),
            [],
        )
        kept = google(attendees=[{"self": False, "responseStatus": "declined"}])
        self.assertEqual(len(parse_events(calendar_sync.calendar_bytes([kept]))), 1)

    def test_repeated_sync_is_stable(self) -> None:
        items = [google(id="recurrence-2"), google(id="recurrence-1")]
        self.assertEqual(
            calendar_sync.calendar_bytes(items), calendar_sync.calendar_bytes(items[::-1])
        )


class FetchTests(unittest.TestCase):
    def test_paginated_fetch_includes_hidden_invitations(self) -> None:
        session = FakeSession(
            FakeResponse({"items": [EVENT], "nextPageToken": "next"}),
            FakeResponse({"items": [{**EVENT, "id": "second"}]}),
        )
        result = calendar_sync.fetch(session, "calendar@example.com", NOW)
        self.assertEqual([e.id for e in result], ["instance-1", "second"])
        self.assertEqual(session.params[-1]["showHiddenInvitations"], "true")
        self.assertEqual(session.params[-1]["pageToken"], "next")

    def test_api_failure_does_not_return_partial_calendar(self) -> None:
        session = FakeSession(FakeResponse({}, fail=True))
        with self.assertRaises(RuntimeError):
            _ = calendar_sync.fetch(session, "calendar@example.com", NOW)


EVENT: dict[str, object] = {
    "id": "instance-1",
    "updated": "2026-10-21T10:00:00Z",
    "start": {"dateTime": "2026-11-02T10:00:00-08:00"},
    "end": {"dateTime": "2026-11-02T11:00:00-08:00"},
}


if __name__ == "__main__":
    _ = unittest.main()
