const duration = 30000;
const visits = new Map();
const borrows = new Map();
const timer = new QTimer();
timer.interval = 250;

// Output and window references can become invalid during display changes.
function guard(handler) {
    let warned = false;
    return (...args) => {
        try {
            handler(...args);
        } catch (error) {
            if (!warned) console.warn("desktop-window-visit: " + error);
            warned = true;
        }
    };
}

function windowId(window) {
    return String(window.internalId);
}

function desktopIds(window) {
    return window.desktops.map(desktop => desktop.id).sort().join(",");
}

function screen(name) {
    return workspace.screens.find(output => output.name === name);
}

function desktop(id) {
    return workspace.desktops.find(candidate => candidate.id === id);
}

function selectedWindow(wantKitty) {
    const output = workspace.activeScreen;
    if (!output) return null;
    const current = workspace.currentDesktopForScreen(output);
    // Reverse stacking order gives the topmost eligible window on this monitor.
    return workspace.stackingOrder.slice().reverse().find(window =>
        window.normalWindow && !window.transient && !window.minimized &&
        window.output === output && window.desktops.length === 1 &&
        window.desktops[0] !== current &&
        (String(window.resourceClass) === "kitty") === wantKitty &&
        (!window.activities.length || window.activities.includes(workspace.currentActivity)));
}

function visitKitty() {
    const window = selectedWindow(true);
    if (!window) return;
    const output = window.output;
    const origin = workspace.currentDesktopForScreen(output);
    if (!origin) return;
    const home = window.desktops[0];
    visits.delete(output.name);
    workspace.setCurrentDesktopForScreen(home, output);
    if (workspace.currentDesktopForScreen(output) !== home) return;
    visits.set(output.name, {
        window: windowId(window), origin: origin.id, home: home.id,
        expires: Date.now() + duration
    });
    timer.start();
    workspace.activeWindow = window;
}

function borrowWindow() {
    const window = selectedWindow(false);
    if (!window) return;
    const output = window.output;
    const current = workspace.currentDesktopForScreen(output);
    if (!current) return;
    const home = window.desktops[0];
    window.desktops = [home, current];
    if (window.desktops.length !== 2 || !window.desktops.includes(home) ||
        !window.desktops.includes(current)) return;
    borrows.set(windowId(window), {
        home: home.id, expected: desktopIds(window),
        expires: Date.now() + duration
    });
    timer.start();
    workspace.activeWindow = window;
}

function settle() {
    const now = Date.now();
    const windows = new Map(workspace.windowList().map(window => [windowId(window), window]));
    for (const [name, visit] of visits) {
        const output = screen(name);
        const origin = desktop(visit.origin);
        if (!output || !origin || workspace.currentDesktopForScreen(output)?.id !== visit.home) {
            visits.delete(name);
            continue;
        }
        const window = windows.get(visit.window);
        if (window && (window.output !== output || desktopIds(window) !== visit.home)) {
            visits.delete(name);
            continue;
        }
        if (now < visit.expires || (window && workspace.activeWindow === window)) continue;
        visits.delete(name);
        workspace.setCurrentDesktopForScreen(origin, output);
    }
    for (const [id, borrow] of borrows) {
        const window = windows.get(id);
        const home = desktop(borrow.home);
        if (!window || !home || desktopIds(window) !== borrow.expected) {
            borrows.delete(id);
            continue;
        }
        if (now < borrow.expires || workspace.activeWindow === window) continue;
        borrows.delete(id);
        window.desktops = [home];
    }
    if (!visits.size && !borrows.size) timer.stop();
}

workspace.currentDesktopChanged.connect(guard((_previous, current, output) => {
    const visit = output && visits.get(output.name);
    if (visit && current?.id !== visit.home) visits.delete(output.name);
}));

function watch(window) {
    const id = windowId(window);
    window.desktopsChanged.connect(() => borrows.delete(id));
}

workspace.windowList().forEach(watch);
workspace.windowAdded.connect(watch);
timer.timeout.connect(guard(settle));
registerShortcut("VisitKittyDesktop", "Temporarily visit a kitty desktop", "Meta+Shift+J", guard(visitKitty));
registerShortcut("BorrowDesktopWindow", "Temporarily borrow a window", "Meta+Shift+B", guard(borrowWindow));
