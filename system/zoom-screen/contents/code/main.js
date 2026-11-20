// New Zoom windows open on DP-1 (the lower-left monitor), so a meeting does
// not take over the main 4K screen. Applied once, when the window appears:
// dragging it elsewhere afterwards sticks for that window.
const TARGET = "DP-1";

function isZoom(w) {
    const cls = String(w.resourceClass || "").toLowerCase();
    const name = String(w.resourceName || "").toLowerCase();
    return cls.startsWith("zoom") || name.startsWith("zoom");
}

function place(w) {
    if (!w || w.deleted || w.fullScreen) return;
    const out = workspace.screens.find(s => s.name === TARGET);
    if (!out || w.output === out) return;
    workspace.sendClientToScreen(w, out);
    // Zoom remembers a size from the 4K screen; shrink it to fit if needed.
    const area = workspace.clientArea(KWin.PlacementArea, out, workspace.currentDesktop);
    const g = w.frameGeometry;
    if (g.width > area.width || g.height > area.height ||
        g.x < area.x || g.y < area.y ||
        g.x + g.width > area.x + area.width || g.y + g.height > area.y + area.height) {
        const width = Math.min(g.width, area.width);
        const height = Math.min(g.height, area.height);
        w.frameGeometry = {
            x: area.x + Math.max(0, (area.width - width) / 2),
            y: area.y + Math.max(0, (area.height - height) / 2),
            width: width, height: height,
        };
    }
}

workspace.windowAdded.connect(function (w) {
    if (!isZoom(w) || w.specialWindow || w.popupWindow) return;
    place(w);
    // Zoom repositions its own windows just after mapping them; check again.
    const t = new QTimer();
    t.singleShot = true;
    t.interval = 400;
    t.timeout.connect(function () { place(w); });
    t.start();
});
