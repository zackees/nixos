#!/usr/bin/env python3
"""Voxtype's private notify-send endpoint; other apps keep using Plasma."""
import argparse
import json
import os
import socket
import struct
import sys


def arguments(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--help", action="help")
    parser.add_argument("-a", "--app-name")
    parser.add_argument("-u", "--urgency")
    parser.add_argument("-t", "--expire-time", type=int, default=18000)
    parser.add_argument("-h", "--hint", action="append", help=argparse.SUPPRESS)
    parser.add_argument("-i", "--icon")
    parser.add_argument("-r", "--replace-id")
    parser.add_argument("-p", "--print-id", action="store_true")
    parser.add_argument("text", nargs="*")
    args = parser.parse_args(argv)
    return {"title": args.text[0] if args.text else "Voxtype",
            "body": args.text[1] if len(args.text) > 1 else "",
            "timeout": args.expire_time}, args.print_id


def address():
    return "\0voxtype-popup-" + str(os.getuid())


def send(argv):
    message, print_id = arguments(argv)
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as connection:
        connection.sendto(json.dumps(message).encode(), address())
    if print_id:
        print(1)


def serve():
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gdk, GLib, Gtk, Gtk4LayerShell as LayerShell, Pango

    Gtk.init()
    window = Gtk.Window(title="Voxtype")
    window.set_decorated(False)
    window.set_default_size(420, -1)
    LayerShell.init_for_window(window)
    LayerShell.set_namespace(window, "voxtype-notifications")
    LayerShell.set_layer(window, LayerShell.Layer.OVERLAY)
    LayerShell.set_keyboard_mode(window, LayerShell.KeyboardMode.NONE)
    for edge in (LayerShell.Edge.BOTTOM, LayerShell.Edge.RIGHT):
        LayerShell.set_anchor(window, edge, True)
    LayerShell.set_margin(window, LayerShell.Edge.BOTTOM, 64)
    LayerShell.set_margin(window, LayerShell.Edge.RIGHT, 16)
    LayerShell.set_exclusive_zone(window, 0)

    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
    for side in ("top", "bottom", "start", "end"):
        getattr(box, "set_margin_" + side)(16)
    header = Gtk.Box(spacing=12)
    title = Gtk.Label(xalign=0, hexpand=True)
    title.add_css_class("heading")
    close = Gtk.Button.new_from_icon_name("window-close-symbolic")
    close.add_css_class("flat")
    close.connect("clicked", lambda *_: window.set_visible(False))
    header.append(title)
    header.append(close)
    body = Gtk.Label(xalign=0, wrap=True, selectable=True)
    body.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
    body.set_max_width_chars(55)
    scroll = Gtk.ScrolledWindow()
    scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scroll.set_propagate_natural_height(True)
    scroll.set_max_content_height(260)
    scroll.set_child(body)
    box.append(header)
    box.append(scroll)
    window.set_child(box)
    css = Gtk.CssProvider()
    css.load_from_data(b"window { background: #242629; color: #eff0f1; border: 1px solid #606367; border-radius: 10px; }")
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, 600)

    connection = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    connection.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
    connection.bind(address())
    timer = None

    def receive(*_):
        nonlocal timer
        data, credentials, _, _ = connection.recvmsg(200000, socket.CMSG_SPACE(12))
        if not any(level == socket.SOL_SOCKET and kind == socket.SCM_CREDENTIALS
                   and struct.unpack("3i", value)[1] == os.getuid()
                   for level, kind, value in credentials):
            return True
        try:
            message = json.loads(data)
            timeout = int(message["timeout"])
            title.set_text(message["title"])
            body.set_text(message["body"])
        except (ValueError, KeyError, TypeError):
            return True
        monitors = Gdk.Display.get_default().get_monitors()
        # This workstation's main display is its large 2560x1440 monitor;
        # both side displays are smaller. Re-evaluate after display changes.
        if monitors.get_n_items():
            monitor = max((monitors.get_item(i) for i in range(monitors.get_n_items())),
                          key=lambda m: m.get_geometry().width * m.get_geometry().height)
            LayerShell.set_monitor(window, monitor)
        if timer is not None:
            GLib.source_remove(timer)
            timer = None
        window.present()
        print("Voxtype popup displayed", flush=True)
        if timeout != 0:
            def hide():
                nonlocal timer
                timer = None
                window.set_visible(False)
                return False
            timer = GLib.timeout_add(timeout if timeout > 0 else 18000, hide)
        return True

    GLib.io_add_watch(connection.fileno(), GLib.IO_IN, receive)
    GLib.MainLoop().run()


if __name__ == "__main__":
    if sys.argv[1:2] == ["--send"]:
        send(sys.argv[2:])
    else:
        serve()
