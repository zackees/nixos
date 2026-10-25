// Report where every kitty window is, and place the ones a restore creates.
// kitty itself cannot know its screen or desktop on Wayland; KWin can.
const NAME = "org.nixos.KittyResurrect";
const PATH = "/org/nixos/KittyResurrect";

function isKitty(w) {
    return w && w.normalWindow && !w.transient && String(w.resourceClass) === "kitty";
}

// Creation order of the windows mapped while this script runs. kitty numbers
// its OS windows in creation order too, which lets the service pair them
// exactly even when every title is the same. Windows that predate the
// script have no number and are paired by focus instead.
let added = 0;
const order = {};

// A window's KWin tile as positions from its desktop's root tile, e.g. [2]
// for the right-hand column. Only custom tiles (the Meta+T layout) count;
// a quick tile lives under a different root and its geometry covers it.
function tilePath(w) {
    const t = w.tile;
    if (!t || !w.output || w.desktops.length !== 1) return null;
    const path = [];
    let node = t;
    while (node.parent) { path.unshift(node.positionInLayout); node = node.parent; }
    return node === workspace.rootTile(w.output, w.desktops[0]) ? path : null;
}

function tileAt(output, desktop, path) {
    let node = workspace.rootTile(output, desktop);
    for (const i of path) {
        node = node && node.tiles[i];
    }
    return node || null;
}

function describe(w) {
    const g = w.frameGeometry;
    return {
        id: String(w.internalId), pid: w.pid, caption: w.caption,
        output: w.output ? w.output.name : "",
        desktops: w.desktops.map(d => d.id),
        x: g.x, y: g.y, width: g.width, height: g.height,
        minimized: w.minimized, active: workspace.activeWindow === w,
        seq: order[String(w.internalId)] ?? -1,
        tile: tilePath(w),
    };
}

// Only settled states: a drag reports once at the end, not per frame.
// `gone` is a window being removed, which may still be in the list.
function push(gone) {
    const live = workspace.windowList().filter(w => isKitty(w) && w !== gone);
    callDBus(NAME, PATH, NAME, "Update", JSON.stringify(live.map(describe)));
}

function place(w, p) {
    const output = workspace.screens.find(s => s.name === p.output);
    if (output && w.output !== output) workspace.sendClientToScreen(w, output);
    const desktops = workspace.desktops.filter(d => p.desktops.includes(d.id));
    if (desktops.length) w.desktops = desktops;
    // Only when the saved rectangle still lands on that screen; after a
    // monitor change KWin's own placement beats a window off in the void.
    if (output) {
        const s = output.geometry;
        if (p.x >= s.x && p.y >= s.y && p.x < s.x + s.width && p.y < s.y + s.height)
            w.frameGeometry = {x: p.x, y: p.y, width: p.width, height: p.height};
    }
    // Last: managing a tile sets the geometry itself. It only takes on the
    // desktop the screen is showing -- on any other one manage() silently
    // does nothing (verified on 6.7.4) -- so a window restored to a desktop
    // in the background is tiled the first time that desktop comes up.
    if (output && desktops.length === 1 && p.tile) {
        pendingTiles.set(w, {output: output, desktop: desktops[0], path: p.tile});
        applyPendingTiles();
    }
    if (p.minimized) w.minimized = true;
}

const pendingTiles = new Map();

function applyPendingTiles() {
    for (const [w, t] of pendingTiles) {
        if (!workspace.windowList().includes(w)) { pendingTiles.delete(w); continue; }
        if (workspace.currentDesktopForScreen(t.output) !== t.desktop) continue;
        const tile = tileAt(t.output, t.desktop, t.path);
        if (tile) tile.manage(w);
        pendingTiles.delete(w);
    }
}
workspace.currentDesktopChanged.connect(applyPendingTiles);

function watch(w) {
    for (const signal of [w.interactiveMoveResizeFinished, w.outputChanged,
                          w.desktopsChanged, w.minimizedChanged, w.tileChanged])
        signal.connect(function () { push(); });
}

workspace.windowList().filter(isKitty).forEach(watch);

workspace.windowAdded.connect(function (w) {
    if (!isKitty(w)) return;
    order[String(w.internalId)] = ++added;
    watch(w);
    // During a restore the service hands each new window its saved place,
    // in launch order; otherwise the answer is empty and nothing moves.
    callDBus(NAME, PATH, NAME, "Claim", String(w.internalId), function (placement) {
        if (!placement) return push();
        const p = JSON.parse(placement);
        place(w, p);
        // kitty's first configure lands after this and resets the size and
        // position; the service's Delay is the only timer a KWin script has.
        callDBus(NAME, PATH, NAME, "Delay", 800, function () {
            if (workspace.windowList().includes(w)) place(w, p);
            push();
        });
    });
});
workspace.windowRemoved.connect(function (w) {
    if (!isKitty(w)) return;
    push(w);
    delete order[String(w.internalId)];
});
workspace.windowActivated.connect(function (w) { if (isKitty(w)) push(); });
push();
