"""Present today's synced calendar to the Plasma agenda; never read credentials."""
import html
import json
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
import re
from urllib.parse import urlparse

from icalendar import Calendar

SOURCE = Path.home() / ".local/share/calendar-sync/google.ics"


def event_link(event):
    for field in ("LOCATION", "DESCRIPTION"):
        for url in re.findall(r'https?://[^\s<>"\']+', html.unescape(str(event.get(field, "")))):
            url = url.rstrip(".,;)")
            host = (urlparse(url).hostname or "").lower()
            if host == "zoom.us" or host.endswith(".zoom.us") or host == "zoom.com" or host.endswith(".zoom.com"):
                return url, "Zoom"
    url = str(event.get("URL", ""))
    return (url, "Calendar") if urlparse(url).scheme in ("http", "https") else ("", "")


def today_agenda(calendar, now):
    local_now = now.astimezone()
    day = local_now.date()
    # Resolve each midnight separately so DST transition days have the right length.
    midnight = datetime.combine(day, time.min).astimezone()
    tomorrow = datetime.combine(day + timedelta(days=1), time.min).astimezone()
    rows = []
    for event in calendar.walk("VEVENT"):
        if str(event.get("STATUS", "")).upper() == "CANCELLED" or "DTSTART" not in event:
            continue
        start = event.decoded("DTSTART")
        end = event.decoded("DTEND") if "DTEND" in event else None
        all_day = isinstance(start, date) and not isinstance(start, datetime)
        if all_day:
            end = end or start + event.decoded("DURATION", timedelta(days=1))
            if not start <= day < end:
                continue
            start_seconds = datetime.combine(start, time.min).astimezone().timestamp()
            end_seconds = datetime.combine(end, time.min).astimezone().timestamp()
            label = "All day"
            status = "all-day"
        else:
            if start.tzinfo is None:
                start = start.astimezone()
            end = end or start + event.decoded("DURATION", timedelta(minutes=1))
            if end.tzinfo is None:
                end = end.astimezone()
            if start >= tomorrow or end <= midnight:
                continue
            start_seconds, end_seconds = start.timestamp(), end.timestamp()
            start_local, end_local = start.astimezone(), end.astimezone()
            label = start_local.strftime("%-I:%M %p") + " – " + end_local.strftime("%-I:%M %p")
            if start_local.date() < day:
                label = "Yesterday " + label
            if end_local.date() > day:
                label += " tomorrow"
            status = "past" if end <= now else "current" if start <= now else "upcoming"
        url, link_kind = event_link(event)
        rows.append({
            "title": str(event.get("SUMMARY", "Untitled meeting")),
            "time": label,
            "start": start_seconds,
            "end": end_seconds,
            "allDay": all_day,
            "status": status,
            "location": str(event.get("LOCATION", "")),
            "url": url,
            "linkKind": link_kind,
        })
    rows.sort(key=lambda row: (not row["allDay"], row["start"], row["title"]))
    timed = [row for row in rows if row["status"] in ("current", "upcoming")]
    next_event = min(timed, key=lambda row: (row["start"], row["linkKind"] != "Zoom")) if timed else None
    if next_event:
        minutes = max(1, int((next_event["start"] - now.timestamp()) / 60 + 0.999))
        next_label = "Now" if next_event["status"] == "current" else datetime.fromtimestamp(next_event["start"]).strftime("%-I:%M %p")
        countdown = "In progress" if next_event["status"] == "current" else f"in {minutes} min" if minutes < 60 else f"in {minutes // 60}h {minutes % 60:02d}m"
    else:
        next_label, countdown = "Today", "No more timed meetings" if rows else "No meetings today"
    return {"date": day.strftime("%A, %B %-d"), "events": rows, "next": next_event,
            "nextLabel": next_label, "countdown": countdown, "error": ""}


def main():
    try:
        data = today_agenda(Calendar.from_ical(SOURCE.read_bytes()), datetime.now(timezone.utc))
    except FileNotFoundError:
        data = {"events": [], "next": None, "nextLabel": "Calendar", "countdown": "Waiting for sync", "error": "Waiting for the first calendar sync."}
    except (OSError, ValueError, TypeError):
        # Do not log calendar contents, private meeting URLs, or parser exceptions.
        data = {"events": [], "next": None, "nextLabel": "Calendar", "countdown": "Calendar unavailable", "error": "Calendar could not be read. The sync will retry."}
    print(json.dumps(data))


if __name__ == "__main__":
    main()
