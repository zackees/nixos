#!/run/current-system/sw/bin/bash
# voxtype's pre_recording_command: return once playback is ducked.
#
# voxtype-ducking.service ducks as soon as voxtype publishes `preparing`,
# which happens before this hook runs, and flags it in levels.ducked. Waiting
# on that flag costs a few ms; starting python to duck again cost ~200 ms of
# the ~500 ms before the microphone opened (#36). If the watcher does not
# answer in 300 ms, duck from here the old way.
flag="$XDG_RUNTIME_DIR/voxtype-ducking/levels.ducked"
for _ in $(seq 60); do
  [ "$(cat "$flag" 2>/dev/null)" = 1 ] && exit 0
  sleep 0.005
done
# Fallback only: uv, never the immutable store python3. This path is already
# the slow one (300 ms of polling failed), so uv's ~30 ms extra does not
# matter, and uv resolves its own managed CPython instead of pinning a
# /nix/store interpreter.
exec "$HOME/.nix-profile/bin/uv" run --no-project --quiet \
  --python-preference only-managed \
  --script "$(dirname "$0")/voxtype-ducking.py" --prepare
