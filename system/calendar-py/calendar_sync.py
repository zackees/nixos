"""Read Google Calendar into a private, read-only KOrganizer calendar.

No Google writes or invitation replies. KDE's reminder daemon handles VALARMs;
this process announces newly seen future events, after an initial quiet sync.
"""

import html
import json
import logging
import os
import subprocess
import time
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Protocol
from urllib.parse import quote, unquote, urlparse

import dbus
from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

import calendar_json
from calendar_ical import IcalAlarm, IcalOutput, write_calendar
from calendar_json import JsonObject

STATE = Path.home() / ".local/share/calendar-sync"
CONFIG = Path.home() / ".config/calendar-sync/config.json"
EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/{}/events"
NOTIFICATION_LIFETIME = 3600
WINDOW = timedelta(days=90)
LOG = logging.getLogger("calendar-sync")


@dataclass(frozen=True, slots=True)
class Attendee:
    """One attendee entry; only our own response matters."""

    is_self: bool
    response_status: str

    @classmethod
    def parse(cls, raw: JsonObject) -> "Attendee":
        """Read an attendee from the Google API."""
        return cls(is_self=raw.flag("self"), response_status=raw.text("responseStatus"))


def parse_time(raw: JsonObject) -> date | datetime:
    """Read a Google start or end: a dateTime, or a date for all-day events."""
    if raw.has("dateTime"):
        # Offset-only TZIDs such as "UTC-07:00" are not portable to KDE.
        # UTC writes a standard trailing Z and needs no VTIMEZONE component.
        return datetime.fromisoformat(raw.required_text("dateTime")).astimezone(UTC)
    return date.fromisoformat(raw.required_text("date"))


@dataclass(frozen=True, slots=True)
class GoogleEvent:
    """A Google Calendar event, parsed eagerly from the API's JSON."""

    id: str
    status: str
    summary: str
    description: str
    location: str
    html_link: str
    hangout_link: str
    updated: datetime
    start: date | datetime
    end: date | datetime
    sequence: int
    attendees: tuple[Attendee, ...]
    transparent: bool
    event_type: str

    @classmethod
    def parse(cls, raw: JsonObject) -> "GoogleEvent":
        """Read an event from the Google API."""
        return cls(
            id=raw.required_text("id"),
            status=raw.text("status"),
            summary=raw.text("summary", "Calendar event"),
            description=raw.text("description"),
            location=raw.text("location"),
            html_link=raw.text("htmlLink"),
            hangout_link=raw.text("hangoutLink"),
            updated=datetime.fromisoformat(raw.required_text("updated")).astimezone(UTC),
            start=parse_time(raw.child("start")),
            end=parse_time(raw.child("end")),
            sequence=raw.integer("sequence"),
            attendees=tuple(Attendee.parse(a) for a in raw.children("attendees")),
            transparent=raw.text("transparency") == "transparent",
            event_type=raw.text("eventType", "default"),
        )

    @property
    def included(self) -> bool:
        """Drop cancelled events and those we declined."""
        return self.status != "cancelled" and not any(
            a.is_self and a.response_status == "declined" for a in self.attendees
        )

    @property
    def invitation(self) -> bool:
        """Report whether we have not answered this invitation yet."""
        return any(a.is_self and a.response_status == "needsAction" for a in self.attendees)


@dataclass(frozen=True, slots=True)
class EventPage:
    """One page of the events list."""

    items: tuple[GoogleEvent, ...]
    next_page_token: str

    @classmethod
    def parse(cls, raw: JsonObject) -> "EventPage":
        """Read a page from the Google API."""
        return cls(
            items=tuple(GoogleEvent.parse(item) for item in raw.children("items")),
            next_page_token=raw.text("nextPageToken"),
        )


@dataclass(frozen=True, slots=True)
class SyncConfig:
    """`~/.config/calendar-sync/config.json`; the key itself stays outside Git."""

    credentials: Path
    calendar_id: str

    @classmethod
    def parse(cls, raw: JsonObject) -> "SyncConfig":
        """Read the configuration."""
        return cls(
            credentials=Path(raw.required_text("credentials")),
            calendar_id=raw.required_text("calendar_id"),
        )


@dataclass(frozen=True, slots=True)
class SeenState:
    """Event IDs already announced, and the window they were fetched over."""

    ids: frozenset[str]
    window_end: datetime

    @classmethod
    def parse(cls, raw: JsonObject) -> "SeenState":
        """Read the saved state."""
        return cls(
            ids=frozenset(raw.strings("ids")),
            window_end=datetime.fromisoformat(raw.required_text("window_end")),
        )

    def to_json(self) -> bytes:
        """Serialize for the next run."""
        document = {"ids": sorted(self.ids), "window_end": self.window_end.isoformat()}
        return json.dumps(document).encode()


class Response(Protocol):
    """The part of `requests.Response` that `fetch` uses."""

    def raise_for_status(self) -> None:
        """Raise for an HTTP error status."""
        ...

    @property
    def text(self) -> str:
        """Return the body."""
        ...


class Session(Protocol):
    """The part of an authorized `requests.Session` that `fetch` uses."""

    def get(self, url: str, *, params: dict[str, str], timeout: int) -> Response:
        """Issue a GET request."""
        ...


class Notifier(Protocol):
    """A freedesktop notification server."""

    owner: str

    def notify(self, summary: str, body: str) -> int:
        """Show a notification; return its ID."""
        ...

    def close(self, notification_id: int) -> None:
        """Close a notification."""
        ...


def atomic_write(path: Path, data: bytes) -> None:
    """Replace `path` without ever exposing a partial file."""
    temporary = path.with_suffix(path.suffix + ".tmp")
    _ = temporary.write_bytes(data)
    _ = temporary.replace(path)


def resource_matches(config_text: str, calendar_path: Path) -> bool:
    """Report whether an Akonadi iCal resource's config points at our file."""
    # KConfig rewrites absolute home paths as Path[$e]=file:$HOME/… .
    for line in config_text.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in ("Path", "Path[$e]"):
            expanded = os.path.expandvars(value)
            path = unquote(urlparse(expanded).path) if expanded.startswith("file:") else expanded
            return Path(path) == calendar_path
    return False


def ical_event(event: GoogleEvent) -> IcalOutput:
    """Describe the VEVENT KOrganizer reads for one Google event."""
    description = event.description
    if event.hangout_link:
        description += "\n" + event.hangout_link
    # All-day events stay visible without waking the user at midnight.
    alarms = (
        tuple(IcalAlarm(event.summary, timedelta(minutes=-m)) for m in (10, 0))
        if isinstance(event.start, datetime)
        else ()
    )
    return IcalOutput(
        uid=event.id + "@calendar-sync",
        start=event.start,
        end=event.end,
        stamp=event.updated,
        sequence=event.sequence,
        summary=event.summary,
        description=description,
        location=event.location,
        url=event.html_link,
        transparent=event.transparent,
        event_type=event.event_type,
        alarms=alarms,
    )


def calendar_bytes(events: Sequence[GoogleEvent]) -> bytes:
    """Render the included events, in a stable order, as iCalendar."""
    ordered = sorted((e for e in events if e.included), key=lambda e: e.id)
    return write_calendar([ical_event(e) for e in ordered])


def fetch(session: Session, calendar_id: str, now: datetime) -> list[GoogleEvent]:
    """Fetch every page; any failure raises rather than return a partial list."""
    params = {
        "singleEvents": "true",
        "showHiddenInvitations": "true",
        "timeMin": (now - timedelta(days=1)).isoformat(),
        "timeMax": (now + WINDOW).isoformat(),
        "maxResults": "2500",
    }
    events: list[GoogleEvent] = []
    while True:
        response = session.get(
            EVENTS_URL.format(quote(calendar_id, safe="")), params=params, timeout=30
        )
        response.raise_for_status()
        page = EventPage.parse(calendar_json.parse(response.text))
        events.extend(page.items)
        if not page.next_page_token:
            return events
        params["pageToken"] = page.next_page_token


class DbusNotifier:
    """The session's notification server, pinned to its current instance."""

    def __init__(self) -> None:
        """Bind to the server that owns the name right now."""
        bus = dbus.SessionBus()
        # Bind to this server instance: notification IDs can be reused after Plasma
        # restarts, so an old timer must never close a new server's notification.
        self.owner: str = str(bus.get_name_owner("org.freedesktop.Notifications"))
        proxy = bus.get_object(self.owner, "/org/freedesktop/Notifications")
        self._interface: dbus.Interface = dbus.Interface(proxy, "org.freedesktop.Notifications")

    def notify(self, summary: str, body: str) -> int:
        """Show a one-hour notification attributed to KOrganizer."""
        result = self._interface.Notify(
            "KOrganizer",
            0,
            # The desktop ID differs from the installed icon's theme name.
            "korganizer",
            summary,
            body,
            dbus.Array([], signature="s"),
            {"desktop-entry": "org.kde.korganizer", "urgency": dbus.Byte(1)},
            NOTIFICATION_LIFETIME * 1000,
        )
        if not isinstance(result, int):
            msg = "Notify returned a non-integer ID"
            raise TypeError(msg)
        return result

    def close(self, notification_id: int) -> None:
        """Close one of our notifications."""
        _ = self._interface.CloseNotification(notification_id)


def close_command(owner: str, notification_id: int, deadline: int) -> list[str]:
    """Build the transient timer that closes a notification at `deadline`."""
    return [
        "systemd-run", "--user", "--quiet", "--collect",
        "--unit=calendar-popup-" + uuid.uuid4().hex,
        "--on-calendar=@" + str(deadline), "--timer-property=AccuracySec=1s",
        "busctl", "--user", "call", owner,
        "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
        "CloseNotification", "u", str(notification_id),
    ]  # fmt: skip


def schedule_close(owner: str, notification_id: int) -> None:
    """Close the notification after its lifetime, even across restarts."""
    # A calendar timer survives this sync process restarting, and wall time
    # includes suspend. Leave one second for systemd's scheduling accuracy.
    deadline = int(time.time() + NOTIFICATION_LIFETIME - 1)
    _ = subprocess.run(close_command(owner, notification_id, deadline), check=True, timeout=10)  # noqa: S603 -- fixed argv


def notification_text(event: GoogleEvent) -> tuple[str, str]:
    """Return the summary line and the escaped markup body."""
    start = event.start
    when = (
        start.astimezone().strftime("%a %b %d, %I:%M %p")
        if isinstance(start, datetime)
        else start.isoformat()
    )
    body = html.escape(event.summary) + "\n" + when
    if event.html_link:
        body += '\n<a href="' + html.escape(event.html_link, quote=True) + '">Open event</a>'
    summary = "New calendar invitation" if event.invitation else "New calendar event"
    return summary, body


def notify(event: GoogleEvent, notifier: Notifier) -> None:
    """Announce a new event; never leave a popup without its expiry."""
    notification_id = notifier.notify(*notification_text(event))
    try:
        schedule_close(notifier.owner, notification_id)
    except Exception:
        # Do not leave an unbounded popup if the independent timer cannot start.
        notifier.close(notification_id)
        raise


def announce(
    events: Sequence[GoogleEvent], previous: SeenState | None, now: datetime
) -> list[GoogleEvent]:
    """Choose events that are new since the last sync and worth a popup."""
    if previous is None:
        # The first sync is quiet: everything is "new".
        return []
    chosen: list[GoogleEvent] = []
    for event in events:
        if event.id in previous.ids or not event.included:
            continue
        start = event.start
        if isinstance(start, datetime):
            future, in_window = start > now, start < previous.window_end
        else:
            future, in_window = start > now.date(), start < previous.window_end.date()
        if future and in_window:
            chosen.append(event)
    return chosen


def _matching_resources(calendar_path: Path) -> list[Path]:
    resources = (Path.home() / ".config").glob("akonadi_ical_resource_*rc")
    return [p for p in resources if resource_matches(p.read_text(), calendar_path)]


def ensure_resource(calendar_path: Path) -> None:
    """Make KOrganizer show our file as one read-only calendar."""
    # Read backend settings on every run: do not duplicate a resource after a
    # restart or require a remembered Akonadi numeric collection identifier.
    matching = _matching_resources(calendar_path)
    created = not matching
    if created:
        _ = subprocess.run(  # noqa: S603 -- fixed argv
            ["konsolekalendar", "--create", str(calendar_path)],  # noqa: S607 -- from the unit's path
            check=True,
            timeout=90,
            stdout=subprocess.DEVNULL,
        )
        matching = _matching_resources(calendar_path)
    for path in matching:
        if "ReadOnly=true" in path.read_text():
            continue
        identifier = path.name.removesuffix("rc")
        # Use introspection for the generated KConfig interface name.
        settings = dbus.SessionBus().get_object(
            "org.freedesktop.Akonadi.Resource." + identifier, "/Settings"
        )
        _ = settings.setReadOnly(True)
        _ = settings.setDisplayName("Google Calendar")
        _ = settings.save()
        manager = dbus.Interface(
            dbus.SessionBus().get_object("org.freedesktop.Akonadi.Control", "/AgentManager"),
            "org.freedesktop.Akonadi.AgentManager",
        )
        _ = manager.setAgentInstanceName(identifier, "Google Calendar")
        _ = manager.restartAgentInstance(identifier)
    if created:
        # A daemon already running during first provisioning can retain its
        # original collection selection. Reload after adding our calendar.
        _ = subprocess.run(
            ["systemctl", "--user", "restart", "app-org.kde.kalendarac@autostart.service"],  # noqa: S607
            check=True,
            timeout=30,
        )


def sync(session: Session, calendar_id: str) -> None:
    """Run one fetch, write, and announce cycle."""
    now = datetime.now(UTC)
    events = fetch(session, calendar_id, now)
    calendar_path = STATE / "google.ics"
    data = calendar_bytes(events)
    if not calendar_path.exists() or calendar_path.read_bytes() != data:
        atomic_write(calendar_path, data)
    ensure_resource(calendar_path)

    seen_path = STATE / "seen.json"
    previous = (
        SeenState.parse(calendar_json.parse(seen_path.read_bytes())) if seen_path.exists() else None
    )
    fresh = announce(events, previous, now)
    if fresh:
        notifier = DbusNotifier()
        for event in fresh:
            notify(event, notifier)
    state = SeenState(ids=frozenset(e.id for e in events), window_end=now + WINDOW)
    atomic_write(seen_path, state.to_json())
    LOG.info("Calendar synchronized: %d events", len(events))


def main() -> None:
    """Sync once a minute, forever."""
    _ = os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    config = SyncConfig.parse(calendar_json.parse(CONFIG.read_bytes()))
    # google-auth leaves this classmethod's parameters unannotated.
    credentials = service_account.Credentials.from_service_account_file(  # pyright: ignore[reportUnknownMemberType]
        str(config.credentials), scopes=["https://www.googleapis.com/auth/calendar.readonly"]
    )
    session = AuthorizedSession(credentials)
    STATE.mkdir(parents=True, exist_ok=True)
    while True:
        try:
            sync(session, config.calendar_id)
        except Exception as error:  # noqa: BLE001 -- the loop must survive any failure
            # HTTP exception text may contain private calendar URLs; keep logs
            # useful without printing credentials or calendar contents.
            LOG.error(  # noqa: TRY400 -- deliberately no traceback
                "Calendar sync failed (%s); retrying in 60s", type(error).__name__
            )
        time.sleep(60)


if __name__ == "__main__":
    main()
