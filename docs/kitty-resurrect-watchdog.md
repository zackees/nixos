# kitty-resurrect black-screen watchdog

Companion to [`kitty-resurrect-safeguards.md`](kitty-resurrect-safeguards.md).
That note makes the restore unable to *cause* a black screen; this one makes
a black screen, whatever caused it, *noticed and corrected* without a human
typing `loginctl activate`.

Code: `system/kitty-resurrect/watchdog.py` (pure, tested by
`test_watchdog.py`), driven from `service.py` every `INTERVAL` seconds.

## 1. Detection: layered signals, cheapest first

| Order | Signal | Source | Cost | Verdict |
|---|---|---|---|---|
| 1 | logind `Active` | `loginctl show-session <seat0 session> -p Active` | one fork | `no` ⇒ `session-inactive` (KWin is not DRM master: the 2026-10-31 cause). Unknown ⇒ `unknown`, never acted on. |
| 2 | KWin journal since last tick | `journalctl --user -u plasma-kwin_wayland --since @T -o cat` | one fork, a few lines | any of `Applying output configuration failed`, `atomic commit failed`, `Failed to find a working output layer configuration` ⇒ `output-errors` |
| 3 | Frame luminance (opt-in) | `spectacle -f -b -n -o` + `magick -format %[fx:mean]` | ~12 MB PNG, ~1 s | mean < `DARK_MEAN` ⇒ `dark-frame`. At most once per `LUMA_INTERVAL`, only when 1 and 2 say ok, and only with `KITTY_RESURRECT_LUMA=1`. |

Signal 3 is off by default: spectacle reads the compositor's buffer, not the
panel, so it cannot see a lost DRM master (the only black screen we have
actually had), and a legitimately dark desktop would read as black.

## 2. Recovery ladder (decision table)

Evaluated by `watchdog.decide()`. Gates come first, in this order:

| Kill switch | Breaker | Attempt cap | Signal | Action |
|---|---|---|---|---|
| on | – | – | – | none (`kill-switch-*`) |
| off | open | – | – | none (`breaker-open`) — desktop untouched |
| off | closed | reached | – | none (`attempt-cap`) |
| off | closed | ok | `ok` / `unknown` | none |
| off | closed | ok | `session-inactive` | **`loginctl activate <session>`** |
| off | closed | ok | `output-errors` / `dark-frame`, session active | **reload the kitty-resurrect KWin script** (never KWin itself) |

Every action is a ledger attempt (`safeguards.Ledger`, persisted in
`watchdog.json`). The next tick re-checks: healthy ⇒ `outcome=ok`, still
unhealthy ⇒ `outcome=failed`. Three failures inside `WINDOW` open the
breaker (`safeguards.BREAKER_FAILURES`), which logs one line and stays open
until the next login or `kitty-resurrect reset`.

Each step logs one greppable line:

    kitty-resurrect watchdog: attempt 1/3 signal=session-inactive action=activate outcome=started

## 3. Thresholds and why

- `INTERVAL = 15 s`: two forks per tick is negligible; 15 s bounds the dark
  time to about one tick plus the re-check.
- Attempt cap / breaker: **reused** from `safeguards.py` (3 attempts, 3
  failures in 600 s). Not duplicated — one source of truth.
- `Ledger.expire(WINDOW)`: attempts older than 600 s are dropped, so three
  *separate* incidents an hour apart are each recoverable, while three
  failures in a row still open the breaker.
- `DARK_MEAN = 0.02`, `LUMA_INTERVAL = 300 s`: a 3-monitor capture is 12 MB;
  once per 5 min is the most we are willing to spend.

## 4. Why it cannot become its own crash loop

- Every action passes the ledger gate; failures open the breaker and stay open.
- The ledger is on disk, so restarting the service does not reset it, and an
  action in flight when the service dies counts as failed.
- The only actions are `loginctl activate` (idempotent) and reloading our own
  KWin script. Nothing restarts KWin, plasmashell or the session.
- The kill switch stops the watchdog with everything else.
- `KITTY_RESURRECT_WATCHDOG_DRY_RUN=1` runs the full ladder and logs
  `dry-run` instead of acting; a test asserts no action runs.

## 5. Enablement path (scripted: `scripts/kitty-resurrect-enable.sh`)

1. `sudo -A nixos-rebuild switch --flake .#nixos`
2. verify `/run/current-system` is the new generation
3. `systemctl --user unmask kitty-resurrect && systemctl --user enable --now kitty-resurrect`
4. journal shows `kitty-resurrect KWin script loaded` and no `LogicalOutput` error
5. screenshot: the full capture is not black, logind session `Active=yes`
6. any failure ⇒ `systemctl --user mask --now kitty-resurrect`, exit non-zero

## 6. Rollback (one command)

    systemctl --user mask --now kitty-resurrect

(`kitty-resurrect disable` is the softer runtime switch; it also stops the watchdog.)
