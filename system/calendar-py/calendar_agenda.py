"""Present today's synced calendar to the Plasma agenda; never read credentials.

Prints one JSON `Feed` for the panel widget, which reruns this every 30 s.
"""

import html
import json
import re
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime, time, timedelta
from enum import StrEnum
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

from calendar_ical import IcalEvent, parse_events

SOURCE = Path.home() / ".local/share/calendar-sync/google.ics"
URL_PATTERN = re.compile(r"https?://[^\s<>\"']+")
# Google event types that describe the user's time rather than a meeting.
BLOCK_EVENT_TYPES = frozenset({"focusTime", "outOfOffice", "workingLocation"})
HOUR_MINUTES = 60
# While a meeting runs, the tab also shows one that starts before it ends or
# within this long after: the back-to-back case worth seeing at a glance.
FOLLOWING_WINDOW = timedelta(hours=1)
# Finished meetings stay in the agenda this long, then drop out of it.
PAST_RETENTION = timedelta(hours=2)


class Status(StrEnum):
    """Where an event sits relative to now."""

    PAST = "past"
    CURRENT = "current"
    UPCOMING = "upcoming"
    ALL_DAY = "all-day"


class LinkKind(StrEnum):
    """What clicking an agenda row opens."""

    ZOOM = "Zoom"
    CALENDAR = "Calendar"
    NONE = ""


@dataclass(frozen=True, slots=True)
class Link:
    """A safe http(s) link for an event."""

    url: str
    kind: LinkKind


NO_LINK = Link("", LinkKind.NONE)


@dataclass(frozen=True, slots=True)
class Row:
    """One agenda entry as the widget renders it."""

    title: str
    time: str
    start: float
    end: float
    all_day: bool
    status: Status
    # A joinable meeting, as opposed to a block of time on the calendar.
    meeting: bool
    location: str
    url: str
    link_kind: LinkKind
    # zoommtg:// URL that opens the Zoom app straight into the meeting, or "".
    join_url: str


@dataclass(frozen=True, slots=True)
class Feed:
    """The whole JSON document the widget reads."""

    date: str
    events: list[Row]
    next: Row | None
    # True while `next` is in progress: the tab shows a red dot.
    live: bool
    # The meeting after a live `next`, when it is close; a second tab slot.
    following: Row | None
    # Today's events trimmed for having ended over PAST_RETENTION ago; tells
    # "all done" apart from "nothing scheduled" once the list is empty.
    finished: int
    # Tomorrow's events, once nothing is left today.
    tomorrow: list[Row]
    next_label: str
    countdown: str
    error: str


def _is_zoom(host: str) -> bool:
    return any(host == domain or host.endswith("." + domain) for domain in ("zoom.us", "zoom.com"))


ZOOM_MEETING_ID = re.compile(r"/(?:j|w|s)/(\d{9,11})/?$")


def zoom_join_url(url: str) -> str:
    """Turn a Zoom web link into the app's own join URL.

    The https link opens a browser tab that then asks to launch the app;
    zoommtg:// is the scheme the Zoom desktop entry handles, so the meeting
    opens immediately. A link without a numeric meeting ID -- a personal
    vanity /my/ link, say -- has no app equivalent and returns "".
    """
    parsed = urlparse(url)
    match = ZOOM_MEETING_ID.search(parsed.path)
    if match is None or not _is_zoom((parsed.hostname or "").lower()):
        return ""
    query = [("action", "join"), ("confno", match.group(1))]
    passwords = parse_qs(parsed.query).get("pwd")
    if passwords:
        query.append(("pwd", passwords[0]))
    return "zoommtg://zoom.us/join?" + urlencode(query)


def event_link(event: IcalEvent) -> Link:
    """Return the event's Zoom link, else its http(s) calendar URL."""
    for field in (event.location, event.description):
        for match in URL_PATTERN.finditer(html.unescape(field)):
            url = match.group(0).rstrip(".,;)")
            if _is_zoom((urlparse(url).hostname or "").lower()):
                return Link(url, LinkKind.ZOOM)
    if urlparse(event.url).scheme in ("http", "https"):
        return Link(event.url, LinkKind.CALENDAR)
    return NO_LINK


def _local(moment: date) -> datetime:
    """Make an aware local datetime; a floating time or bare date is local."""
    if isinstance(moment, datetime):
        return moment.astimezone()
    return datetime.combine(moment, time.min).astimezone()


def _clock(moment: datetime) -> str:
    return moment.strftime("%-I:%M %p")


def _row(event: IcalEvent, day: date, now: datetime) -> Row | None:
    """Build the agenda row, or None when the event is not on `day`."""
    all_day = not isinstance(event.start, datetime)
    start = _local(event.start)
    if event.end is not None:
        end = _local(event.end)
    else:
        default = timedelta(days=1) if all_day else timedelta(minutes=1)
        end = start + (event.duration or default)
    midnight = _local(day)
    # Resolve each midnight separately so DST transition days have the right length.
    tomorrow = _local(day + timedelta(days=1))
    if start >= tomorrow or end <= midnight:
        return None
    if all_day:
        label, status = "All day", Status.ALL_DAY
    else:
        label = _clock(start) + " – " + _clock(end)
        if start.date() < day:
            label = "Yesterday " + label
        if end.date() > day:
            label += " tomorrow"
        if end <= now:
            status = Status.PAST
        elif start <= now:
            status = Status.CURRENT
        else:
            status = Status.UPCOMING
    link = event_link(event)
    meeting = (
        not all_day
        and link.kind is LinkKind.ZOOM
        and not event.transparent
        and event.event_type not in BLOCK_EVENT_TYPES
    )
    return Row(
        title=event.summary or "Untitled meeting",
        time=label,
        start=start.timestamp(),
        end=end.timestamp(),
        all_day=all_day,
        status=status,
        meeting=meeting,
        location=event.location,
        url=link.url,
        link_kind=link.kind,
        join_url=zoom_join_url(link.url) if link.kind is LinkKind.ZOOM else "",
    )


def select_next(rows: list[Row]) -> Row | None:
    """Choose the event the tab shows.

    A meeting in progress stays selected until it ends; otherwise the next
    meeting to start. Calendar blocks overlap meetings freely, so they are
    considered only when no meeting remains today -- a long block that began
    earlier must not hold the tab on its start time.
    """
    live = [row for row in rows if row.status in (Status.CURRENT, Status.UPCOMING)]
    pool = [row for row in live if row.meeting] or live
    current = [row for row in pool if row.status is Status.CURRENT]
    return min(current or pool, key=lambda row: (row.start, row.end, row.title), default=None)


def select_following(rows: list[Row], chosen: Row | None) -> Row | None:
    """Choose the meeting after a live one, if it starts soon enough to matter."""
    if chosen is None or chosen.status is not Status.CURRENT:
        return None
    horizon = chosen.end + FOLLOWING_WINDOW.total_seconds()
    soon = [
        row
        for row in rows
        if row is not chosen
        and row.status is Status.UPCOMING
        and row.meeting == chosen.meeting
        and row.start < horizon
    ]
    return min(soon, key=lambda row: (row.start, row.end, row.title), default=None)


def _countdown(row: Row, now: datetime) -> str:
    if row.status is Status.CURRENT:
        return "In progress"
    minutes = max(1, int((row.start - now.timestamp()) / 60 + 0.999))
    if minutes < HOUR_MINUTES:
        return f"in {minutes} min"
    return f"in {minutes // HOUR_MINUTES}h {minutes % HOUR_MINUTES:02d}m"


def _rows_on(events: list[IcalEvent], day: date, now: datetime) -> list[Row]:
    rows = [row for event in events if (row := _row(event, day, now))]
    rows.sort(key=lambda row: (not row.all_day, row.start, row.title))
    return rows


def today_agenda(events: list[IcalEvent], now: datetime) -> Feed:
    """Build today's feed at `now`, which must be timezone-aware."""
    day = now.astimezone().date()
    live = [event for event in events if not event.cancelled]
    scheduled = _rows_on(live, day, now)
    cutoff = (now - PAST_RETENTION).timestamp()
    rows = [row for row in scheduled if row.status is not Status.PAST or row.end >= cutoff]
    chosen = select_next(rows)
    tomorrow: list[Row] = []
    if chosen is None:
        # Leave out events already listed today, such as one running past midnight.
        midnight = _local(day + timedelta(days=1)).timestamp()
        tomorrow = [
            row
            for row in _rows_on(live, day + timedelta(days=1), now)
            if row.all_day or row.start >= midnight
        ]
        label = "Today"
        if not scheduled:
            countdown = "No meetings today"
        elif any(row.status is not Status.ALL_DAY for row in scheduled):
            countdown = "All of today's meetings are done"
        else:
            countdown = "No more timed meetings"
    else:
        label = (
            "Now"
            if chosen.status is Status.CURRENT
            else _clock(_local(datetime.fromtimestamp(chosen.start, UTC)))
        )
        countdown = _countdown(chosen, now)
    return Feed(
        date=day.strftime("%A, %B %-d"),
        events=rows,
        next=chosen,
        live=chosen is not None and chosen.status is Status.CURRENT,
        following=select_following(rows, chosen),
        finished=len(scheduled) - len(rows),
        tomorrow=tomorrow,
        next_label=label,
        countdown=countdown,
        error="",
    )


def _failure(countdown: str, error: str) -> Feed:
    return Feed(
        date="",
        events=[],
        next=None,
        live=False,
        following=None,
        finished=0,
        tomorrow=[],
        next_label="Calendar",
        countdown=countdown,
        error=error,
    )


def main() -> None:
    """Print the feed for the current moment."""
    try:
        feed = today_agenda(parse_events(SOURCE.read_bytes()), datetime.now(UTC))
    except FileNotFoundError:
        feed = _failure("Waiting for sync", "Waiting for the first calendar sync.")
    except (OSError, ValueError):  # ParseError is a ValueError
        # Do not log calendar contents, private meeting URLs, or parser exceptions.
        feed = _failure("Calendar unavailable", "Calendar could not be read. The sync will retry.")
    print(json.dumps(asdict(feed)))  # noqa: T201 -- stdout is the widget's feed


if __name__ == "__main__":
    main()
