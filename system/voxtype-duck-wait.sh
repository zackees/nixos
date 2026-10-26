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
exec /run/current-system/sw/bin/python3 "$HOME/.local/libexec/voxtype-ducking.py" --prepare
