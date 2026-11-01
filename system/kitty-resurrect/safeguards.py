"""The decisions that keep kitty-resurrect from ever degrading the desktop.

Pure Python, no D-Bus, so every rule is unit-tested (test_safeguards.py) and
service.py only asks. See docs/kitty-resurrect-safeguards.md for why each
exists; in short:
  disabled()          kill switch, checked before any work
  Ledger.gate()       attempt cap + backoff + circuit breaker, persisted
  outputs_unhealthy() never act while the session/outputs are degraded
  summary()           one greppable line per decision
"""
import json
import os
from pathlib import Path

MAX_ATTEMPTS = 3        # automatic attempts per login session
BASE_DELAY = 5          # s; attempt n waits BASE_DELAY * 2**(n-1)
MAX_DELAY = 300
WINDOW = 600            # s; BREAKER_FAILURES failures inside it open the breaker
BREAKER_FAILURES = 3
STABLE_FOR = 10         # s the output set must be unchanged before a restore

KILL_ENV = "KITTY_RESURRECT_DISABLE"


def kill_file(env=os.environ):
    base = env.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "kitty-resurrect" / "disabled"


def disabled(env, path):
    """A reason string while resurrect is switched off, else None."""
    if env.get(KILL_ENV, "") not in ("", "0"):
        return "kill-switch-env"
    if path.exists():
        return "kill-switch-file"
    return None


def backoff(n):
    return min(BASE_DELAY * 2 ** max(n - 1, 0), MAX_DELAY)


def summary(n, total, outcome, reason, next_delay):
    nxt = "none" if next_delay is None else f"{int(next_delay)}s"
    return f"kitty-resurrect: attempt {n}/{total} outcome={outcome} reason={reason} next={nxt}"


def outputs_unhealthy(outputs, session_active, changed, now, stable_for=STABLE_FOR):
    """Why a restore must not run now, or None when it may.

    `outputs` is the KWin script's last report (None if it never reported),
    `session_active` logind's view (None if unknown), `changed` when the
    report last differed. An inactive session has no DRM master: that is the
    state the 2026-10-31 black screens were in.
    """
    if not session_active:
        return "session-inactive"
    if outputs is None:
        return "no-output-report"
    if not outputs:
        return "no-outputs"
    if any(int(o.get("width") or 0) <= 0 or int(o.get("height") or 0) <= 0 for o in outputs):
        return "output-degraded"
    if now - changed < stable_for:
        return "outputs-settling"
    return None


class Decision:
    def __init__(self, allowed, reason, attempt, delay):
        self.allowed, self.reason, self.attempt, self.delay = allowed, reason, attempt, delay

    def __repr__(self):
        return f"Decision({self.allowed}, {self.reason!r}, {self.attempt}, {self.delay})"


class Ledger:
    """Attempts and breaker state for one login session, kept on disk so a
    crashing service cannot reset its own limits by restarting."""

    def __init__(self, path, log=print):
        self.path = Path(path)
        self.log = log
        try:
            data = json.loads(self.path.read_text())
            if not isinstance(data, dict):
                raise ValueError
        except (OSError, ValueError):
            data = {}
        self.session = data.get("session")
        self.attempts = [a for a in data.get("attempts", []) if isinstance(a, dict)]
        self.breaker = data.get("breaker") or None
        # An attempt the previous service never finished died with it.
        for a in self.attempts:
            if a.get("outcome") == "started":
                a["outcome"] = "failed"
                a["reason"] = "in-flight-at-exit"

    @property
    def breaker_open(self):
        return bool(self.breaker)

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(".tmp-" + self.path.name)
        tmp.write_text(json.dumps({"session": self.session, "attempts": self.attempts,
                                   "breaker": self.breaker}))
        os.replace(tmp, self.path)

    def begin_session(self, session):
        """A new login is the explicit trigger that closes the breaker."""
        if session != self.session:
            self.session, self.attempts, self.breaker = session, [], None
            self.save()
        else:
            self._check_breaker()

    def reset(self):
        self.attempts, self.breaker = [], None
        self.save()
        self.log("kitty-resurrect: breaker reset by operator")

    def gate(self, now):
        self._check_breaker(now)
        n = len(self.attempts) + 1
        if self.breaker:
            return Decision(False, "breaker-open", n, None)
        if n > MAX_ATTEMPTS:
            return Decision(False, "attempt-cap", n, None)
        return Decision(True, "ok", n, backoff(n))

    def start(self, now):
        self.attempts.append({"t": now, "outcome": "started"})
        self.save()

    def finish(self, outcome, now, reason=""):
        if self.attempts and self.attempts[-1].get("outcome") == "started":
            self.attempts[-1].update(outcome=outcome, reason=reason, end=now)
        self._check_breaker(now)
        self.save()

    def _check_breaker(self, now=None):
        if self.breaker:
            return
        fails = [a["t"] for a in self.attempts if a.get("outcome") == "failed"]
        if now is None:
            now = max([a.get("t", 0) for a in self.attempts], default=0)
        recent = [t for t in fails if now - t <= WINDOW]
        if len(recent) >= BREAKER_FAILURES:
            self.breaker = {"since": now, "failures": len(recent)}
            self.save()
            self.log(f"kitty-resurrect: breaker open after {len(recent)} failed attempts "
                     f"in {WINDOW}s; staying down until next login or `kitty-resurrect reset`")
