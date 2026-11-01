# kitty-resurrect: what blacked out the screens on 2026-10-31, and the safeguards

Status: `kitty-resurrect.service` is masked. It was masked as an emergency
measure, and turning it back on is the operator's call (see "Re-enabling"
below).

## 1. Root cause chain (from `journalctl -b`, 2026-10-31)

There are **two separate chains**. The kitty-resurrect script shows up in the
logs next to the black screens, but it was not what caused them.

### A. The black screens: a VT-switch chord, not the script

Each time the outputs died, it happened a few seconds after kernal-api's
`examples/global-hotkey.rs` (in `~/dev/kernal-api`) registered its default
chord through the GlobalShortcuts portal. That default is **Ctrl+Alt+F9**,
which is also the kernel's "switch to VT 9" chord. The example then prints
"press it within 30s":

```
13:27:03.5209 xdg-desktop-portal-kde: BindShortcuts ... preferred_trigger "CTRL+ALT+F9"
13:27:08.5676 kwin_wayland: Failed to find a working output layer configuration!
13:27:08.5693 kwin_wayland: Applying output configuration failed!
13:27:08.5801 kwin_wayland: atomic commit failed: Permission denied
13:29:16.2913 sudo: loginctl activate 3          <- recovery
13:33:02.7856 BindShortcuts ... "CTRL+ALT+F9"
13:33:14.8057 kwin_wayland: atomic commit failed: Permission denied
13:33:48 / 13:33:59 sudo: loginctl activate [3]
13:34:20.7367 BindShortcuts ... "CTRL+ALT+F9"
13:34:27.7854 kwin_wayland: Failed to find a working output layer configuration!
13:34:27.7895 kwin_wayland: atomic commit failed: Permission denied
13:34:45.5576 sudo: loginctl activate 3
```

`atomic commit failed: Permission denied` means KWin is no longer DRM master.
logind takes DRM master away when the session stops being the active one on
its seat, and a VT switch is exactly that. The way it was fixed confirms this:
`loginctl activate 3` (switch back to session 3 on tty2) brought the outputs
back every time. Nothing restarted KWin and nothing crashed: `kwin_wayland`
kept the same pid (3672) through every incident.

The journal does not record keystrokes, so it cannot show who pressed the
chord: the user, or an agent testing the example. Either way it was the VT
switch, and nothing kitty-resurrect did reaches that path.

**The decisive evidence:** the failures at 13:33:14 and 13:34:27 have **no
kitty-resurrect message anywhere near them**. The last TypeError was at
13:30:08. The script cannot be the trigger for failures it took no part in.

Follow-up (outside this repo): the kernal-api example should not default to a
`Ctrl+Alt+F<n>` chord. On Linux, Ctrl+Alt+F1 through F12 belong to the
kernel's VT switching.

### B. The TypeErrors: a real defect in our script (fixed in c1b818d)

```
13:25:40.9085 kwin_wayland: "Could not convert argument 0 ... to KWin::LogicalOutput*"
                  applyPendingTiles@.../y38aipdm...-kitty-resurrect/.../main.js:85
13:26:58.6091  (same)
13:30:05.8586  (same)
13:30:08.7934  (same)
```

In the old `main.js`, line 85 was
`workspace.currentDesktopForScreen(t.output)`. `place()` had saved a
`LogicalOutput` object in `pendingTiles`. KWin replaces those objects whenever
the outputs are reconfigured: monitor sleep, a hotplug, or the VT round-trips
in chain A. So the saved object went stale.

**Why it repeated:** the exception was thrown *before*
`pendingTiles.delete(w)`, so the bad entry was never removed. Every later
desktop switch (`currentDesktopChanged`) ran into it again: 13:25, 13:26, and
twice at 13:30. It is a stale entry hitting the same throw over and over, not
a loop that re-runs resurrect. The service did nothing in this window, and the
journal shows no restores.

The defect is **ours**. It is in `system/kitty-resurrect/main.js`, not in
kitty or a kitty plugin. There is no upstream kitty "session-resurrect
plugin": the saving side is our own `kitty_snapshot.py`. So nothing upstream
needed a fork. c1b818d (#47) fixed it: outputs are held by name and resolved
just before each call, and every entry point goes through `guard()`.

### C. Ways it could have looped (found in `service.py`, not triggered)

- Every time `org.kde.KWin` gets a new owner, the service calls `load()` and
  then `check_restore()`. If KWin itself is crash-looping, each restart
  restores the newest dead kitty state. A restored kitty that dies with the
  next KWin crash leaves a new dead state behind, so the next KWin start
  restores that one. Nothing caps the number of attempts and nothing backs
  off.
- `Restart=on-failure` with `RestartSec=2` and no start limit lets a crashing
  service respawn without bound.
- Nothing checks the session or the outputs first. A restore can start while
  the session is inactive (no DRM master) or while the outputs are still
  settling.
- There is no runtime off switch. Masking the unit was the only option.

## 2. Safeguards

The decision logic lives in `system/kitty-resurrect/safeguards.py`. It is pure
Python with no D-Bus, so it can be tested on its own. `service.py` asks it
before doing any work.

| # | Safeguard | Control | Why it is the right control |
|---|---|---|---|
| 1 | Attempt cap and backoff | At most 3 automatic attempts per login session. Attempt n waits `5 s * 2^(n-1)`, capped at 300 s. | Bounds chain C's KWin-restart loop no matter what triggers it. |
| 2 | Circuit breaker | 3 failed attempts within 10 min open the breaker. It logs one line, persists in `guard.json`, and stays open until a new login session or `kitty-resurrect reset`. An attempt still "in flight" when the service dies counts as a failure. | A crash during a restore is the very loop we fear. Counting it is how the breaker sees it. |
| 3 | Output stability | Restore only when the logind session is **Active**, KWin has reported at least one output with real geometry, and the output set has not changed for 10 s. Otherwise skip, logging the reason. | Chain A's failure mode was an inactive session and outputs in flux. Never act while in that state. |
| 4 | Isolation from KWin | Every `main.js` entry point, including the new `screensChanged` reporter, runs under `guard()`. A target that cannot be resolved means do nothing. The service never loads the script while disabled. | An exception can never land inside KWin's own signal emission. |
| 5 | Kill switch | Resurrect is off while `~/.config/kitty-resurrect/disabled` exists or `KITTY_RESURRECT_DISABLE=1` is set. Checked before any work: load, restore, D-Bus calls, and the 10 s tick, which also unloads the KWin script. | One step, takes effect at runtime, no rebuild. |
| 6 | Self-observation | One line per decision, for example `kitty-resurrect: attempt 2/3 outcome=skipped reason=session-inactive next=10s`. | A loop shows up in a single `journalctl --user -u kitty-resurrect | grep attempt`. |

The unit also gets `StartLimitBurst=3` within `StartLimitIntervalSec=300` and
`RestartSec=5`, so a crashing service stops after three tries instead of
respawning forever.

## 3. Tests

- `system/kitty-resurrect/test_safeguards.py` (stdlib `unittest`) has one test
  class per safeguard: cap and backoff, breaker (open, persisted, in-flight
  counts as failed, reset by login and by operator), output stability
  (inactive session, no report, zero geometry, recent change), kill switch
  (file and env), and the summary line format.
- `system/kitty-resurrect/main.test.mjs` (`node --test`) runs `main.js`
  against a mock KWin that rejects stale outputs. It now also checks that
  outputs are reported, and that a `workspace` which throws on every access
  cannot push an exception out of any signal handler.
- Both suites run **inside the Nix build** of the `kitty-resurrect`
  derivation. If either fails, `nixos-rebuild build` fails.

## 4. Rollback

Each of these leaves the desktop untouched, because the service unloads its
KWin script before it stops:

- `kitty-resurrect disable` creates the kill-switch file. This takes effect
  within 10 s, and the KWin script is unloaded. `kitty-resurrect enable`
  removes the file.
- `systemctl --user mask --now kitty-resurrect` turns it off completely, as
  is the case today.

## 5. Re-enabling (operator)

1. `sudo -A nixos-rebuild switch --flake .#nixos` to activate the safeguards.
2. `systemctl --user unmask kitty-resurrect && systemctl --user start kitty-resurrect`
3. `journalctl --user -u kitty-resurrect -f`. Expect `kitty-resurrect KWin
   script loaded`. If there is a dead state, also expect an `attempt 1/3 ...`
   line.
4. Check state at any time with `kitty-resurrect status`.
