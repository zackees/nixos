// Remember focus before a newly mapped window has a chance to take it.
let activeId = workspace.activeWindow ? String(workspace.activeWindow.internalId) : "";
let previousActiveId = "";
workspace.windowActivated.connect(function (window) {
    const id = window ? String(window.internalId) : "";
    if (id !== activeId) {
        previousActiveId = activeId;
        activeId = id;
    }
});

// Only new top-level windows participate. Existing windows, transient dialogs,
// all-desktop windows, and restored placement on another desktop are preserved.
workspace.windowAdded.connect(function (window) {
    if (!window.normalWindow || window.transient || window.onAllDesktops || window.pid <= 1) return;
    const id = String(window.internalId);
    const priorFocus = activeId === id ? previousActiveId : activeId;
    const originalDesktops = window.desktops.map(d => d.id).join(",");
    const originalOutput = window.output;
    const current = workspace.currentDesktopForScreen(originalOutput);
    if (window.desktops.length !== 1 || window.desktops[0] !== current) return;
    const sources = workspace.windowList().filter(w =>
        String(w.internalId) !== id && w.normalWindow && !w.transient &&
        !w.onAllDesktops && w.pid > 1);
    const snapshot = sources.map(w => ({id: String(w.internalId), pid: w.pid, caption: w.captionNormal}));
    callDBus("org.nixos.LaunchOrigin", "/org/nixos/LaunchOrigin",
             "org.nixos.LaunchOrigin", "Resolve", String(window.pid), JSON.stringify(snapshot),
             function (sourceId) {
        const live = workspace.windowList();
        const target = live.find(w => String(w.internalId) === id);
        const source = live.find(w => String(w.internalId) === sourceId);
        if (!target || !source || source.onAllDesktops || target.onAllDesktops) return;
        if (snapshot.filter(w => w.pid === source.pid).length > 1) {
            const originalSource = snapshot.find(w => w.id === sourceId);
            if (!originalSource || originalSource.caption !== source.captionNormal) return;
        }
        // Do not undo a user's move, a window rule, or an app changing its own
        // placement while the asynchronous process lookup was running.
        if (target.output !== originalOutput ||
            target.desktops.map(d => d.id).join(",") !== originalDesktops) return;
        const desktops = source.desktops.slice();
        if (!desktops.length) return;
        const background = !desktops.includes(workspace.currentDesktopForScreen(source.output));
        if ((background || target.output !== source.output) && workspace.activeWindow === target) {
            const prior = live.find(w => String(w.internalId) === priorFocus);
            const visible = prior && !prior.minimized &&
                (prior.onAllDesktops || prior.desktops.includes(workspace.currentDesktopForScreen(prior.output))) &&
                (!prior.activities.length || prior.activities.includes(workspace.currentActivity));
            // sendClientToScreen changes the active output when its window is
            // active. Restore only focus stolen by this new window, before
            // moving it; never activate a hidden prior window or change desks.
            workspace.activeWindow = visible ? prior : null;
        }
        if (target.output !== source.output) workspace.sendClientToScreen(target, source.output);
        target.desktops = desktops;
        // Deliberately never activate the new window or change a screen's desktop.
    });
});
