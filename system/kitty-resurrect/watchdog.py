"""Notice a black screen and correct it, bounded. docs/kitty-resurrect-watchdog.md

Pure: the probe and the actions are injected, so service.py supplies loginctl,
journalctl and D-Bus while the tests supply fakes. The attempt cap, breaker
and kill switch are safeguards.py's; this module only consumes them.
"""
import safeguards as sg

INTERVAL = 15          # s between ticks
LIT_MIN = 0.001        # fraction of pixels >10% bright below which a frame is black
LUMA_INTERVAL = 300    # s; never capture the 12 MB frame more often
KWIN_UNIT = "plasma-kwin_wayland"
OUTPUT_ERRORS = (
    "Applying output configuration failed",
    "atomic commit failed",
    "Failed to find a working output layer configuration",
)


def classify(session_active, journal, luma=None):
    """Cheapest signal first: logind, then KWin's journal, then the frame."""
    if session_active is None:
        return "unknown"
    if not session_active:
        return "session-inactive"
    if any(err in journal for err in OUTPUT_ERRORS):
        return "output-errors"
    if luma is not None and luma < LIT_MIN:
        return "dark-frame"
    return "ok"


def decide(signal, disabled, breaker_open, cap_reached, session_active):
    """(action or None, reason): the decision table in the doc, row by row."""
    if disabled:
        return None, disabled
    if breaker_open:
        return None, "breaker-open"
    if cap_reached:
        return None, "attempt-cap"
    if signal == "ok":
        return None, "healthy"
    if signal == "unknown":
        return None, "unknown"
    if not session_active:
        return "activate", signal
    return "reload-script", signal


def line(n, signal, action, outcome):
    return (f"kitty-resurrect watchdog: attempt {n}/{sg.MAX_ATTEMPTS} "
            f"signal={signal} action={action} outcome={outcome}")


class Watchdog:
    def __init__(self, ledger, probe, actions, disabled, log=print, dry_run=False, luma=None):
        self.ledger, self.probe, self.actions = ledger, probe, actions
        self.disabled, self.log, self.dry_run, self.luma = disabled, log, dry_run, luma
        self.since = None
        self.action = None
        self.quiet = None      # last no-action reason logged; log changes only

    def tick(self, now):
        if self.disabled():
            return None
        since, self.since = self.since, now
        active, journal = self.probe(since)
        luma = None
        if self.luma and active and not any(e in journal for e in OUTPUT_ERRORS):
            luma = self.luma(now)
        signal = classify(active, journal, luma)

        last = self.ledger.attempts[-1] if self.ledger.attempts else None
        if last and last.get("outcome") == "started":
            outcome = "ok" if signal == "ok" else "failed"
            self.ledger.finish(outcome, now, signal)
            self.log(line(len(self.ledger.attempts), signal, self.action or "-", outcome))

        self.ledger.expire(now)
        gate = self.ledger.gate(now)
        action, reason = decide(signal, None, self.ledger.breaker_open,
                                not gate.allowed and gate.reason == "attempt-cap", active)
        if action is None:
            if signal != "ok" and reason != self.quiet:
                self.log(line(gate.attempt, signal, "none", reason))
            self.quiet = None if signal == "ok" else reason
            return None
        self.quiet = None
        self.action = action
        self.ledger.start(now)
        if self.dry_run:
            self.log(line(gate.attempt, signal, action, "dry-run"))
        else:
            self.log(line(gate.attempt, signal, action, "started"))
            try:
                self.actions[action]()
            except Exception as error:  # noqa: BLE001 - logged, then judged next tick
                self.log(line(gate.attempt, signal, action, f"error:{type(error).__name__}"))
        return action
