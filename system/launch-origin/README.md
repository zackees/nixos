# Launch-origin placement

Issue [#14](https://github.com/zackees/nixos/issues/14): a terminal/app on
another desktop starts a new window, which incorrectly appears on the
currently active desktop. The original live reproduction had parent=6,
child=7, active=7.

`main.js` listens only for new normal KWin windows. `service.py` resolves
their local process ancestry over the user session bus. The nearest ancestor
with an unambiguous window supplies desktop membership and monitor. The
script restores focus only if this new window took it, before moving the
window across outputs (KWin's `sendToOutput` otherwise changes active output).
It never switches virtual desktops. Transient dialogs use KWin's existing
parent handling; existing windows, all-desktop windows, and windows already
placed off the current desktop are left alone. A user/app move during the
asynchronous lookup cancels placement.

Kitty shares one process across OS windows. Its `tab_bar.py` loads the
read-only `kitty_bridge.py` from the current system, including on config
reload. A main-loop timer publishes pane IDs and window titles to a mode-0600
file under `XDG_RUNTIME_DIR` every half second. `KITTY_PID` and
`KITTY_WINDOW_ID` identify the pane; a unique title within that process
identifies its KWin window. Process start time and snapshot age prevent stale
metadata reuse. Full environments and command lines are never logged or
saved. This does not enable remote control of the user's terminals.

Limits are deliberate: identical kitty OS-window titles, custom fixed OS
titles that differ from the pane title, missing/stale metadata, ambiguous
non-kitty process ownership, and lost process ancestry retain normal KWin
placement. A detached kitty descendant can still use inherited pane identity.
Existing-process IPC handoffs (including `kitty --single-instance` creating
a new terminal, browser reuse, and D-Bus activation) do not expose a reliable
caller PID and are not solved by ancestry. Dock launch timing is also outside
this policy; the user's confirmed case is an app/terminal on another desktop.
Because placement follows the window-added event, a new window can briefly
appear before being moved. Fast kitty launches get up to half a second for
the next metadata heartbeat; the compositor is never blocked for this.

The service starts with the graphical session, reloads its script if KWin
restarts, and unloads it on service stop. No compositor restart is required.
Disable live with `systemctl --user stop launch-origin`; re-enable with
`systemctl --user start launch-origin`. Reload kitty with
`pkill -USR1 -x .kitty-wrapped` after deploying its tab-bar hook.

Validation:

```sh
python3 -m unittest discover -s system/launch-origin -v
ruff check system/launch-origin home/kitty/tab_bar.py
nixos-rebuild build --flake .#nixos
```

After activation, the live regression opens and closes only its temporary
terminals, and restores the previously focused window:

```sh
python3 system/launch-origin/repro.py
python3 system/launch-origin/repro.py --shared
python3 system/launch-origin/repro.py --shared \
  --observer-position 1600 100 --source-position 20 850
```

The last positions use this host's current HDMI-A-1 and DP-3 logical monitor
geometry; adjust them if the display arrangement changes. No dock or Plasma
panel configuration is involved.
