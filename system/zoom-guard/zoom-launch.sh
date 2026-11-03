#!@bash@
# Zoom launcher: settings profile from zoom-guard, then Zoom as its own
# app-Zoom@ unit (see the comment on zoom-us-prioritised in
# configuration.nix), plus a watcher that records how the run ends.
#
# zoom-guard (system/zoom-guard/zoom_guard.py) picks the profile so a forced
# setting that breaks Zoom cannot wedge it in a crash -> relaunch loop. It
# fails open: if it errors or hangs, the GPU profile below is used, which is
# exactly what this launcher did before the guard existed.
#
# Rank-0 profile, kept in step with PROFILES[0] in zoom_guard.py:
#   EGL/OCL: Zoom's FHS sandbox mounts a tmpfs /etc with no /etc/egl or
#     /etc/OpenCL/vendors, so it fell back to llvmpipe and CPU effects
#     (2026-11-02); /run/opengl-driver is visible inside the sandbox.
#   xwayland: native Wayland drew the camera self-view black on NVIDIA's
#     GLES path (2026-11-03); XWayland uses desktop GL, still the GPU.
#   enablehardwareacc*: inert on Linux (no NVENC backend), set in case.
default='PROFILE gpu-xwayland 0
ENV __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS /run/opengl-driver/share/egl/egl_external_platform.d
ENV OCL_ICD_VENDORS /run/opengl-driver/etc/OpenCL/vendors
CONF xwayland true
CONF enablegpucomputeutilization true
CONF enablehardwareaccforvideosend true
CONF enablehardwareaccforvideoreceive true'

# A Zoom already running takes the request itself (single instance). Touch
# nothing: Zoom rewrites zoomus.conf on exit, and the guard must never
# disturb a live meeting.
if @pgrep@ -u "$(id -u)" -x zoom >/dev/null; then
  exec @zoom@ "$@"
fi

profile=$(@timeout@ 10 @guard@ pre) || profile=
case "$profile" in
  "PROFILE "*" "[0-9]*) ;;
  *) profile=$default ;;   # guard failed, or disabled
esac

conf="${XDG_CONFIG_HOME:-$HOME/.config}/zoomus.conf"
rank=0
envargs=()
while read -r kind key value; do
  case "$kind" in
    PROFILE) rank=$value ;;
    ENV) export "$key=$value"; envargs+=(-E "$key=$value") ;;
    CONF) [ -f "$conf" ] && @crudini@ --set "$conf" General "$key" "$value" ;;
  esac
done <<<"$profile"

watch() {
  @systemd_run@ --user --quiet --collect --unit="zoom-guard-watch-$$" \
    @guard@ watch "$1" "$rank" || true
}

# Launched from the dock, KDE already made this an app-Zoom@ unit.
unit=$(@grep@ -o 'app-Zoom@[^/]*\.service' /proc/self/cgroup)
if [ -n "$unit" ]; then
  watch "$unit"
  exec @zoom@ "$@"
fi
watch "app-Zoom@$$.service"
exec @systemd_run@ --user --quiet --collect --unit="app-Zoom@$$.service" \
  "${envargs[@]}" @zoom@ "$@"
