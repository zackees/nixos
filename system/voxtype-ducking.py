# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
#
# Run only through `uv run --script` (the voxtypeDucking wrapper in
# system/configuration.nix for the watcher, and voxtype's pre_recording_command
# for --prepare --wait) -- never with the store python3, which is PEP 668-
# managed and pinned to a /nix/store interpreter. Standard library only, so the
# dependency list stays empty.
"""Duck physical playback devices while Voxtype records, independent of apps.

Only output channel gains change: microphone gain, mute, routing, virtual OBS
mixes and application volumes stay under their existing controls. The journal
is saved before changing gains so ExecStopPost can recover after a crash.
"""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

GAIN = 0.25  # -12.04 dB in PipeWire's linear amplitude units.


def run(*args):
    command = str(Path('/run/current-system/sw/bin') / args[0])
    return subprocess.run((command, *args[1:]), check=True, capture_output=True,
                          text=True, timeout=3).stdout


def playback_devices():
    devices = {}
    for obj in json.loads(run('pw-dump')):
        info = obj.get('info', {})
        props = info.get('props', {})
        if (props.get('media.class') != 'Audio/Sink' or 'device.id' not in props
                or props.get('node.virtual') in (True, 'true')):
            continue
        for param in info.get('params', {}).get('Props', []):
            volumes = param.get('channelVolumes')
            if volumes and all(math.isfinite(v) and v >= 0 for v in volumes):
                devices[props['node.name']] = {'id': obj['id'], 'volumes': volumes}
                break
    return devices


def set_volumes(node, volumes):
    run('pw-cli', 'set-param', str(node), 'Props', json.dumps({'channelVolumes': volumes}))


def same_levels(a, b):
    # ALSA hardware/software gain splitting can round values slightly.
    return len(a) == len(b) and all(math.isclose(x, y, rel_tol=0.02, abs_tol=0.00002)
                                   for x, y in zip(a, b))


def watcher_running():
    return subprocess.run(['/run/current-system/sw/bin/systemctl', '--user',
                           'is-active', '--quiet', 'voxtype-ducking.service'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          timeout=3).returncode == 0


class Ducker:
    def __init__(self, journal, snapshot=playback_devices, change=set_volumes):
        self.journal = journal
        self.snapshot = snapshot
        self.change = change
        self.saved = json.loads(journal.read_text()) if journal.exists() else {}

    def save(self):
        temporary = self.journal.with_suffix('.next')
        temporary.write_text(json.dumps(self.saved))
        temporary.replace(self.journal)

    def reload(self):
        self.saved = json.loads(self.journal.read_text()) if self.journal.exists() else {}

    def update(self, recording):
        devices = self.snapshot()
        if recording:
            for name, device in devices.items():
                if name in self.saved:
                    continue
                original = device['volumes'][:]
                lowered = [v * GAIN for v in original]
                self.saved[name] = {'original': original, 'lowered': lowered}
                self.save()
                self.change(device['id'], lowered)
        else:
            for name, entry in list(self.saved.items()):
                device = devices.get(name)
                if device is None:
                    continue  # Keep recovery data until an unplugged device returns.
                if same_levels(device['volumes'], entry['lowered']):
                    self.change(device['id'], entry['original'])
                # A manual volume change while dictating takes precedence.
                del self.saved[name]
                self.save()


def watcher_answered(flag, timeout):
    """True once the watcher has flagged playback as ducked, within timeout.

    Polling a file is what keeps the pre-capture hook cheap: the watcher ducks
    as soon as voxtype publishes `preparing`, which happens *before* the hook
    runs, so the usual case is one read rather than a second interpreter
    starting up. This used to be a bash script (voxtype-duck-wait.sh) for the
    same reason; folding it in here keeps one implementation instead of two
    while uv's ~30 ms start is only paid on the path that has already given up
    waiting.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if flag.read_text().strip() == '1':
                return True
        except FileNotFoundError:
            pass
        time.sleep(0.005)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restore', action='store_true')
    parser.add_argument('--prepare', action='store_true',
                        help='Synchronously duck before the start cue and capture')
    parser.add_argument('--wait', action='store_true',
                        help='With --prepare, let the watcher duck first and only '
                             'duck here if it does not answer in --wait-timeout')
    parser.add_argument('--wait-timeout', type=float, default=0.3,
                        help='Seconds to wait for the watcher (default 0.3)')
    parser.add_argument('--state', type=Path)
    parser.add_argument('--journal', type=Path)
    args = parser.parse_args()
    runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    state = args.state or runtime / 'voxtype/state'
    journal = args.journal or runtime / 'voxtype-ducking/levels.json'
    journal.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    ducker = Ducker(journal)
    # The synchronous start hook and state watcher share one recovery journal.
    # Lock both the read and write so they cannot double-duck or lose originals.
    ducked = journal.with_suffix('.ducked')
    if args.prepare and not args.restore and args.wait:
        # The watcher ducks as soon as voxtype publishes `preparing`, which is
        # before this hook runs, so the common case is one read of the flag it
        # writes. Duck synchronously below if it does not answer in time.
        if watcher_running() and watcher_answered(ducked, args.wait_timeout):
            return
    with journal.with_suffix('.lock').open('a') as lock:
        if args.restore or args.prepare:
            if args.prepare and not args.restore and not watcher_running():
                return  # Preserve the user's explicit "stop ducking" override.
            fcntl.flock(lock, fcntl.LOCK_EX)
            ducker.reload()
            ducker.update(args.prepare and not args.restore)
            if args.prepare and not args.restore:
                try:
                    if not watcher_running():
                        ducker.update(False)
                except Exception:
                    ducker.update(False)
                    raise
            return
    stopped = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopped.set())
    previous = None
    refresh_at = 0
    try:
        while not stopped.is_set():
            with journal.with_suffix('.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                try:
                    recording = state.read_text().strip() in ('preparing', 'recording')
                except FileNotFoundError:
                    recording = False
                ducker.reload()
                now = time.monotonic()
                if recording != previous or (now >= refresh_at and (recording or ducker.saved)):
                    ducker.update(recording)
                    ducked.write_text('1' if recording else '0')
                    if recording != previous:
                        print('Playback ducked by 12 dB' if recording else 'Playback restored', flush=True)
                    previous = recording
                    refresh_at = now + 0.5
            stopped.wait(0.02)
    finally:
        with journal.with_suffix('.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            ducker.reload()
            ducker.update(False)
            ducked.write_text('0')


if __name__ == '__main__':
    main()
