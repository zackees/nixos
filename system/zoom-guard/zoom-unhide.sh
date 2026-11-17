# zoom-unhide: bring a vanished Zoom meeting window back onto the current
# desktop on the largest screen.
#
# Zoom's Linux client (XWayland) sometimes *unmaps* its "Meeting" window
# instead of minimising it -- after minimise-to-floating-video, or after a
# screen share ends -- and then never maps it again (2026-11-16; the same
# report on Fedora: discussion.fedoraproject.org/t/179121). An unmapped X11
# window is not a window as far as KWin is concerned: it is in no task
# manager, on no desktop, and Alt-Tab cannot reach it, while the meeting
# itself (audio, camera) keeps running. The X server still has it, so
# mapping it again from outside restores it intact.
set -u

pgrep -u "$(id -u)" -x zoom >/dev/null || { echo "zoom is not running" >&2; exit 1; }

mapped=0
for w in $(xdotool search --class '^zoom$' 2>/dev/null); do
  name=$(xdotool getwindowname "$w" 2>/dev/null) || continue
  case "$name" in
    Meeting|"Zoom Meeting"|"Zoom Workplace"*) ;;
    *) continue ;;
  esac
  # Withdrawn, not minimised: a minimised X11 window is unmapped too, but
  # keeps WM_STATE Iconic and KWin still lists it. The lost one has no
  # WM_STATE at all (or Withdrawn), which is what Zoom left on 2026-11-16.
  if xwininfo -id "$w" | grep -q 'Map State: IsUnMapped' &&
     ! xprop -id "$w" WM_STATE | grep -qE 'Normal|Iconic'; then
    # A real top-level is never tiny; Zoom's helper windows are.
    if [ "$(xwininfo -id "$w" | awk '/^  Width:/{print $2}')" -gt 200 ]; then
      xdotool windowmap "$w" && echo "mapped: $name ($w)" && mapped=$((mapped+1))
    fi
  fi
done

# Now that KWin manages it again, put every Zoom meeting window on the
# current desktop, on the largest screen, unminimised, and focus it.
js=$(mktemp --suffix=.js)
trap 'rm -f "$js"' EXIT
cat > "$js" <<'KWINJS'
var outs = workspace.screens, big = outs[0];
for (var j = 1; j < outs.length; j++)
  if (outs[j].geometry.width * outs[j].geometry.height >
      big.geometry.width * big.geometry.height) big = outs[j];
var g = big.geometry, ws = workspace.windowList(), target = null;
for (var i = 0; i < ws.length; i++) {
  var w = ws[i];
  if (w.resourceClass != "zoom" || !w.normalWindow) continue;
  if (w.caption == "Meeting" || w.caption == "Zoom Meeting") target = w;
  else if (!target && /^Zoom Workplace/.test(w.caption)) target = w;
}
if (target) {
  target.desktops = [workspace.currentDesktop];
  target.minimized = false;
  var f = target.frameGeometry;
  var wd = Math.min(f.width, g.width - 80), ht = Math.min(f.height, g.height - 80);
  target.frameGeometry = { x: g.x + (g.width - wd) / 2, y: g.y + (g.height - ht) / 2,
                           width: wd, height: ht };
  workspace.activeWindow = target;
}
KWINJS
name="zoom-unhide-$$"
id=$(qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$js" "$name")
qdbus org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null
qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null
echo "restored ($mapped re-mapped)"
