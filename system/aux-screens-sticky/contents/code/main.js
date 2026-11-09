const MAIN = "HDMI-A-1";
const managed = new Set();
function apply(w) {
  if (!w || !w.normalWindow || !w.output) return;
  const onMain = w.output.name === MAIN;
  if (!onMain && !w.onAllDesktops) { w.onAllDesktops = true; managed.add(w.internalId.toString()); }
  else if (onMain && managed.has(w.internalId.toString())) {
    managed.delete(w.internalId.toString());
    w.onAllDesktops = false; w.desktops = [workspace.currentDesktop];
  }
}
function hook(w) { apply(w); w.outputChanged.connect(() => apply(w)); }
workspace.windowList().forEach(hook);
workspace.windowAdded.connect(hook);
