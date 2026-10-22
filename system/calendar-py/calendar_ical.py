"""The one place that touches icalendar's untyped API.

Every VEVENT is parsed eagerly into an `IcalEvent`; nothing outside this module
sees an icalendar object.
"""

from dataclasses import dataclass
from datetime import date, datetime, timedelta

from icalendar import Calendar, Component


class ParseError(ValueError):
    """The calendar file holds a value of an unexpected type."""


@dataclass(frozen=True, slots=True)
class IcalEvent:
    """One VEVENT, with every field the agenda uses already typed."""

    summary: str
    start: date | datetime
    end: date | datetime | None
    duration: timedelta | None
    cancelled: bool
    location: str
    description: str
    url: str
    # TRANSP:TRANSPARENT marks time that does not block availability.
    transparent: bool
    # Google's eventType ("default", "focusTime", "workingLocation", ...).
    event_type: str


def _text(component: Component, key: str) -> str:
    value = component.get(key)
    return "" if value is None else str(value)


def _when(component: Component, key: str) -> date | datetime | None:
    if key not in component:
        return None
    value = component.decoded(key)
    # datetime subclasses date, so this accepts both.
    if not isinstance(value, date):
        msg = f"{key} is not a date"
        raise ParseError(msg)
    return value


def _duration(component: Component) -> timedelta | None:
    if "DURATION" not in component:
        return None
    value = component.decoded("DURATION")
    if not isinstance(value, timedelta):
        msg = "DURATION is not a duration"
        raise ParseError(msg)
    return value


def parse_event(component: Component) -> IcalEvent | None:
    """Parse one VEVENT; return None for an event with no start."""
    start = _when(component, "DTSTART")
    if start is None:
        return None
    return IcalEvent(
        summary=_text(component, "SUMMARY"),
        start=start,
        end=_when(component, "DTEND"),
        duration=_duration(component),
        cancelled=_text(component, "STATUS").upper() == "CANCELLED",
        location=_text(component, "LOCATION"),
        description=_text(component, "DESCRIPTION"),
        url=_text(component, "URL"),
        transparent=_text(component, "TRANSP").upper() == "TRANSPARENT",
        event_type=_text(component, "X-GOOGLE-EVENT-TYPE"),
    )


def parse_events(data: bytes) -> list[IcalEvent]:
    """Parse every VEVENT in an iCalendar document."""
    events = (parse_event(c) for c in Calendar.from_ical(data).walk("VEVENT"))
    return [event for event in events if event is not None]
