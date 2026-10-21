"""Duck physical playback devices while Voxtype records, independent of apps.

Only output channel gains change: microphone gain, mute, routing, virtual OBS
mixes and application volumes stay under their existing controls. The journal
is saved before changing gains so ExecStopPost can recover after a crash.
"""
import argparse
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
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=3).stdout


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restore', action='store_true')
    parser.add_argument('--state', type=Path)
    parser.add_argument('--journal', type=Path)
    args = parser.parse_args()
    runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    state = args.state or runtime / 'voxtype/state'
    journal = args.journal or runtime / 'voxtype-ducking/levels.json'
    journal.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    ducker = Ducker(journal)
    if args.restore:
        ducker.update(False)
        return
    stopped = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopped.set())
    previous = None
    refresh_at = 0
    try:
        while not stopped.is_set():
            try:
                recording = state.read_text().strip() == 'recording'
            except FileNotFoundError:
                recording = False
            now = time.monotonic()
            if recording != previous or (now >= refresh_at and (recording or ducker.saved)):
                ducker.update(recording)
                if recording != previous:
                    print('Playback ducked by 12 dB' if recording else 'Playback restored', flush=True)
                previous = recording
                refresh_at = now + 0.5
            stopped.wait(0.05)
    finally:
        ducker.update(False)


if __name__ == '__main__':
    main()
