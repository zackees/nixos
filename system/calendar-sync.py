"""Read Google Calendar into a private, read-only KOrganizer calendar.

No Google writes or invitation replies. KDE's reminder daemon handles VALARMs;
this process announces newly seen future events, after an initial quiet sync.
"""

import html
import json
import logging
import os
from pathlib import Path
import subprocess
import time
import uuid
from datetime import date, datetime, timedelta, timezone
from urllib.parse import quote, unquote, urlparse

import dbus
from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account
from icalendar import Alarm, Calendar, Event

UTC = timezone.utc
STATE = Path.home() / ".local/share/calendar-sync"


def atomic_write(path, data):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def parse_time(value):
    if "dateTime" in value:
        # Offset-only TZIDs such as "UTC-07:00" are not portable to KDE.
        # UTC writes a standard trailing Z and needs no VTIMEZONE component.
        return datetime.fromisoformat(value["dateTime"].replace("Z", "+00:00")).astimezone(UTC)
    return date.fromisoformat(value["date"])


def resource_matches(config_text, calendar_path):
    # KConfig rewrites absolute home paths as Path[$e]=file:$HOME/… .
    for line in config_text.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in ("Path", "Path[$e]"):
            value = os.path.expandvars(value)
            path = unquote(urlparse(value).path) if value.startswith("file:") else value
            return Path(path) == calendar_path
    return False


def included(item):
    return item.get("status") != "cancelled" and not any(
        a.get("self") and a.get("responseStatus") == "declined"
        for a in item.get("attendees", [])
    )


def calendar_bytes(items):
    calendar = Calendar()
    calendar.add("prodid", "-//nixos//Google Calendar desktop sync//EN")
    calendar.add("version", "2.0")
    calendar.add("x-wr-calname", "Google Calendar")
    for item in sorted(items, key=lambda e: e["id"]):
        if not included(item):
            continue
        event = Event()
        event.add("uid", item["id"] + "@calendar-sync")
        event.add("dtstart", parse_time(item["start"]))
        event.add("dtend", parse_time(item["end"]))
        event.add("dtstamp", parse_time({"dateTime": item["updated"]}))
        event.add("last-modified", parse_time({"dateTime": item["updated"]}))
        event.add("sequence", item.get("sequence", 0))
        event.add("summary", item.get("summary", "Calendar event"))
        description = item.get("description", "")
        if item.get("hangoutLink"):
            description += "\n" + item["hangoutLink"]
        event.add("description", description)
        event.add("location", item.get("location", ""))
        if item.get("htmlLink"):
            event.add("url", item["htmlLink"])
        # All-day events stay visible without waking the user at midnight.
        if "dateTime" in item["start"]:
            for minutes in (10, 0):
                alarm = Alarm()
                alarm.add("action", "DISPLAY")
                alarm.add("description", item.get("summary", "Calendar event"))
                alarm.add("trigger", -timedelta(minutes=minutes))
                event.add_component(alarm)
        calendar.add_component(event)
    return calendar.to_ical()


def fetch(session, calendar_id, now):
    params = {
        "singleEvents": "true", "showHiddenInvitations": "true",
        "timeMin": (now - timedelta(days=1)).isoformat(),
        "timeMax": (now + timedelta(days=90)).isoformat(),
        "maxResults": 2500,
    }
    items = []
    while True:
        response = session.get(
            "https://www.googleapis.com/calendar/v3/calendars/"
            + quote(calendar_id, safe="") + "/events",
            params=params, timeout=30,
        )
        response.raise_for_status()
        payload = response.json()
        items.extend(payload.get("items", []))
        if not payload.get("nextPageToken"):
            return items
        params["pageToken"] = payload["nextPageToken"]


def notifications():
    bus = dbus.SessionBus()
    # Bind to this server instance: notification IDs can be reused after Plasma
    # restarts, so an old timer must never close a new server's notification.
    owner = bus.get_name_owner("org.freedesktop.Notifications")
    proxy = bus.get_object(
        owner, "/org/freedesktop/Notifications"
    )
    return owner, dbus.Interface(proxy, "org.freedesktop.Notifications")


def schedule_close(owner, notification_id, lifetime=3600):
    # A calendar timer survives this sync process restarting, and wall time
    # includes suspend. Leave one second for systemd's scheduling accuracy.
    deadline = int(time.time() + lifetime - 1)
    subprocess.run([
        "systemd-run", "--user", "--quiet", "--collect",
        "--unit=calendar-popup-" + uuid.uuid4().hex,
        "--on-calendar=@" + str(deadline), "--timer-property=AccuracySec=1s",
        "busctl", "--user", "call", str(owner),
        "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
        "CloseNotification", "u", str(notification_id),
    ], check=True, timeout=10)


def notify(item):
    owner, interface = notifications()
    start = parse_time(item["start"])
    when = (start.astimezone().strftime("%a %b %d, %I:%M %p")
            if isinstance(start, datetime) else start.isoformat())
    invitation = any(a.get("self") and a.get("responseStatus") == "needsAction"
                     for a in item.get("attendees", []))
    body = html.escape(item.get("summary", "Calendar event")) + "\n" + when
    if item.get("htmlLink"):
        body += '\n<a href="' + html.escape(item["htmlLink"], quote=True) + '">Open event</a>'
    notification_id = interface.Notify(
        "KOrganizer", 0, "korganizer",
        "New calendar invitation" if invitation else "New calendar event",
        body, dbus.Array([], signature="s"),
        {"desktop-entry": "org.kde.korganizer", "urgency": dbus.Byte(1)}, 3600000,
    )
    try:
        schedule_close(owner, notification_id)
    except Exception:
        # Do not leave an unbounded popup if the independent timer cannot start.
        interface.CloseNotification(notification_id)
        raise


def sync(session, calendar_id):
    now = datetime.now(UTC)
    items = fetch(session, calendar_id, now)
    calendar_path = STATE / "google.ics"
    data = calendar_bytes(items)
    if not calendar_path.exists() or calendar_path.read_bytes() != data:
        atomic_write(calendar_path, data)

    # Read backend settings on every run: do not duplicate a resource after a
    # restart or require a remembered Akonadi numeric collection identifier.
    resources = list((Path.home() / ".config").glob("akonadi_ical_resource_*rc"))
    matching = [p for p in resources if resource_matches(p.read_text(), calendar_path)]
    created = not matching
    if not matching:
        subprocess.run(["konsolekalendar", "--create", str(calendar_path)],
                       check=True, timeout=90, stdout=subprocess.DEVNULL)
        matching = [p for p in (Path.home() / ".config").glob("akonadi_ical_resource_*rc")
                    if resource_matches(p.read_text(), calendar_path)]
    for path in matching:
        if "ReadOnly=true" in path.read_text():
            continue
        identifier = path.name.removesuffix("rc")
        # Use introspection for the generated KConfig interface name.
        settings = dbus.SessionBus().get_object(
            "org.freedesktop.Akonadi.Resource." + identifier, "/Settings"
        )
        settings.setReadOnly(True)
        settings.setDisplayName("Google Calendar")
        settings.save()
        manager = dbus.Interface(dbus.SessionBus().get_object(
            "org.freedesktop.Akonadi.Control", "/AgentManager"
        ), "org.freedesktop.Akonadi.AgentManager")
        manager.setAgentInstanceName(identifier, "Google Calendar")
        manager.restartAgentInstance(identifier)
    if created:
        # A daemon already running during first provisioning can retain its
        # original collection selection. Reload after adding our calendar.
        subprocess.run(["systemctl", "--user", "restart",
                        "app-org.kde.kalendarac@autostart.service"],
                       check=True, timeout=30)

    seen_path = STATE / "seen.json"
    previous = json.loads(seen_path.read_text()) if seen_path.exists() else None
    seen = set(previous["ids"]) if previous else None
    current = {item["id"] for item in items}
    if seen is not None:
        for item in items:
            if item["id"] in seen or not included(item):
                continue
            start = parse_time(item["start"])
            future = start > now if isinstance(start, datetime) else start > now.date()
            previous_end = datetime.fromisoformat(previous["window_end"])
            in_window = (start < previous_end if isinstance(start, datetime)
                         else start < previous_end.date())
            if future and in_window:
                notify(item)
    atomic_write(seen_path, json.dumps({
        "ids": sorted(current), "window_end": (now + timedelta(days=90)).isoformat()
    }).encode())
    logging.info("Calendar synchronized: %d events", len(items))


def main():
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    config = json.loads((Path.home() / ".config/calendar-sync/config.json").read_text())
    credentials = service_account.Credentials.from_service_account_file(
        config["credentials"], scopes=["https://www.googleapis.com/auth/calendar.readonly"]
    )
    session = AuthorizedSession(credentials)
    STATE.mkdir(parents=True, exist_ok=True)
    while True:
        try:
            sync(session, config["calendar_id"])
        except Exception as error:
            # HTTP exception text may contain private calendar URLs; keep logs
            # useful without printing credentials or calendar contents.
            logging.error("Calendar sync failed (%s); retrying in 60s", type(error).__name__)
        time.sleep(60)


if __name__ == "__main__":
    main()
