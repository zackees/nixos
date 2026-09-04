---
name: streamdeck
description: Configure the Elgato Stream Deck XL by editing Boatswain's JSON profile directly, rather than driving its GTK UI. Use when asked to add, change, or remove Stream Deck buttons, or when Boatswain will not start, shows no window, or ignores a newly installed application.
---

# Configuring the Stream Deck

The device is an Elgato Stream Deck XL, `0fd9:006c`, 32 keys in an 8x4 grid,
serial `CL22K1A01009`. The client is **boatswain** (`environment.systemPackages`
in `system/configuration.nix`), chosen over `streamdeck-ui` because it drives OBS
natively and is GTK4, so it survives this machine's fractional scaling.

## Edit the JSON. Do not automate the GUI.

Boatswain's entire configuration is one plain, pretty-printed JSON file:

    ~/.local/share/<serial>.json      ->  ~/.local/share/CL22K1A01009.json

Editing it is quick and deterministic. Driving the app with `ydotool` was tried
and is a dead end: the window moves between screenshots, `spectacle -u` hangs,
and on this 1.5x/1.75x/1x multi-monitor setup the logical and capture coordinate
scales do not agree. Reading the format took a fraction of the effort.

## Procedure

1. **Stop Boatswain.** It rewrites the whole file on save and on quit, so an
   edit made while it runs is silently discarded -- the same trap as plasmashell
   and `appletsrc`. See the stopping notes below; it is fiddlier than it looks.
2. Back the file up, then edit it.
3. Start Boatswain and confirm the keys render.

## File shape

`items` is positional: exactly one entry per key, 32 for the XL, in reading
order. An unconfigured key is `{}`.

```json
{ "active-profile": "<uuid>",
  "profiles": [ { "id": "<uuid>", "name": "Default", "brightness": 0.5,
    "page": { "version": 1, "regions": [ { "id": "main-button-grid",
      "region-data": {}, "items": [ "...32 entries..." ] } ] } } ] }
```

A button that launches an application:

```json
{ "type": "action", "factory": "launcher", "action": "launch-action",
  "settings": { "app": "com.obsproject.Studio.desktop", "files": [] } }
```

`app` is the desktop-file id as `g_app_info_get_id` reports it -- the basename,
including `.desktop`. The key's icon comes from that entry, which is why a
custom launcher (see `chatgptLauncher` in `system/configuration.nix`) is worth
declaring: it carries its own glyph with no per-key image to set by hand.

A button that opens a URL (verified with Boatswain 5.0; the `go/hermes` key
used this until 2026-09-03, when it became a `launch-action` on
`pyweb-view.hermes.desktop` -- an entry in `~/.local/share/applications`,
which Boatswain does enumerate -- so Hermes opens as its own native window
instead of a browser tab. The URL form still resolves through the `go` hosts
entry and nginx redirect in `system/configuration.nix`):

```json
{ "type": "action", "factory": "launcher", "action": "launcher-open-url-action",
  "custom-icon": { "background-color": "rgba(0,0,0,0)", "text": null,
                   "file": "file:///home/niteris/.local/share/streamdeck-icons/go-hermes.svg" },
  "settings": { "url": "http://go/hermes" } }
```

Note the action name is `launcher-open-url-action`, with the plugin prefix,
unlike `launch-action`. A URL button has no desktop entry to take an icon
from, so `custom-icon.file` is what draws the key; SVG works. Boatswain
reformats the whole file on its next start, so a hand edit shows up in the
next capture as a large whitespace-only diff -- that is expected.

Two things that make a correct-looking `app` bind to nothing:

- Loading **skips any app failing `g_app_info_should_show`**, so an entry marked
  `NoDisplay=true` is silently ignored. Prefer `brave-browser.desktop` over
  `com.brave.Browser.desktop` for exactly this reason.
- Boatswain enumerates desktop entries **at startup**, so anything installed
  after it launched is invisible until it restarts.

Other action types live under `src/plugins/` upstream -- `launcher` (also
`open-file-action`, `open-url-action`), `obs-studio`, `soundboard`, `network`,
`desktop`, `gaming`. Read the plugin's `*-action.c` for its `settings` keys
before guessing.

## Stopping and starting it

Three separate traps, all hit for real:

- `pkill -x boatswain` matches nothing. The Nix wrapper means the process name
  is `.boatswain-wrap`.
- `pkill -f boatswain-wrapped` **kills your own shell**, because the pattern
  matches the command line invoking it. Write `boatswain-wrap[p]ed`, or kill by
  pid.
- It is a single-instance GApplication. If one is already running, a second
  invocation hands off and exits, which looks exactly like a launch that did
  nothing.
- On this NixOS desktop, the autostarted instance is managed as
  `app-com.feaneron.Boatswain@autostart.service`. Use `systemctl --user stop`
  and `systemctl --user start` on that exact unit when editing the profile;
  this was verified with Boatswain 5.0. It avoids relying on the wrapper's
  process name and guarantees the restarted app rereads the JSON.

Outside a Flatpak sandbox it also logs

    Error requesting background: Only sandboxed applications can set background status

and can sit running with **no window at all**. A live pid is not evidence of a
visible app; check with KWin:

```
qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript <script> name
```

listing `workspace.windowList()` and looking for `com.feaneron.Boatswain`.

## Upstream source

If the format shifts, these are the files that define it, in
<https://gitlab.gnome.org/World/boatswain>:

- `lib/bs-device.c` -- `get_profile_path` (the `<serial>.json` path) and
  `save_profiles` (the JSON writer)
- `lib/bs-profile.c`, `lib/bs-page.c`, `lib/bs-page-item.c` -- profile, page and
  per-key serialisation
- `src/plugins/launcher/launcher-launch-action.c` -- how `app` is read and written

## Keep this skill current

**This file is meant to grow.** It exists because working the above out from
scratch cost a long, wrong detour through GUI automation. Whenever you learn
something here that a future run would otherwise rediscover, add it:

- a new action type's `settings` keys, once used for real
- anything that made a button silently fail to bind
- behaviour that changes after a `boatswain` version bump
- whatever replaces this if the client is ever swapped out

Record what was **verified**, and say plainly when something is untested --
a confident wrong note is worse than no note. The repo's own history is the
style reference: explain *why*, not just *what*.
