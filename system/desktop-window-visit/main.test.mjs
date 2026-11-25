import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";

const source = readFileSync(new URL("./contents/code/main.js", import.meta.url), "utf8");

function signal() {
    const callbacks = [];
    return {
        connect(callback) { callbacks.push(callback); },
        emit(...args) { callbacks.forEach(callback => callback(...args)); },
    };
}

function fixture() {
    const here = { id: "here" };
    const home = { id: "home" };
    const other = { id: "other" };
    const main = { name: "HDMI-A-1", current: here };
    const side = { name: "DP-1", current: other };

    function makeWindow(resourceClass) {
        let desktops = [home];
        return {
            internalId: resourceClass, resourceClass, normalWindow: true, output: main,
            activities: [], desktopsChanged: signal(), outputChanged: signal(),
            interactiveMoveResizeStarted: signal(),
            get desktops() { return desktops; },
            set desktops(value) {
                desktops = Array.from(value);
                this.desktopsChanged.emit();
            },
        };
    }

    const kitty = makeWindow("kitty");
    const app = makeWindow("browser");
    const workspace = {
        screens: [main, side], desktops: [here, home, other], activeScreen: main,
        activeWindow: null, currentDesktopChanged: signal(), windowAdded: signal(),
        windowList() { return [kitty, app]; },
        get stackingOrder() { return this.windowList(); },
        currentDesktopForScreen(output) { return output.current; },
        setCurrentDesktopForScreen(current, output) {
            const previous = output.current;
            output.current = current;
            this.currentDesktopChanged.emit(previous, current, output);
        },
    };
    const shortcuts = new Map();
    let now = 0;
    let timer;
    class QTimer {
        constructor() { timer = this; }
        timeout = signal();
        start() { this.running = true; }
        stop() { this.running = false; }
    }
    runInNewContext(source, {
        workspace, QTimer, Date: { now: () => now },
        registerShortcut(id, _description, _key, callback) { shortcuts.set(id, callback); },
    });
    return {
        kitty, app, main, side, here, home, other, workspace,
        visit: shortcuts.get("VisitKittyDesktop"),
        borrow: shortcuts.get("BorrowDesktopWindow"),
        tick(at) {
            now = at;
            if (timer.running) timer.timeout.emit();
        },
    };
}

test("kitty visit returns only its monitor after expiry and focus loss", () => {
    const f = fixture();
    f.visit();
    assert.equal(f.main.current, f.home);
    assert.equal(f.side.current, f.other);
    assert.deepEqual(f.kitty.desktops, [f.home]);
    assert.equal(f.workspace.activeWindow, f.kitty);
    f.tick(30000);
    assert.equal(f.main.current, f.home);
    f.workspace.activeWindow = null;
    f.tick(30250);
    assert.equal(f.main.current, f.here);
    assert.deepEqual(f.kitty.desktops, [f.home]);
});

test("a manual desktop switch cancels the visit, even if switched back", () => {
    const f = fixture();
    f.visit();
    f.workspace.setCurrentDesktopForScreen(f.other, f.main);
    f.workspace.setCurrentDesktopForScreen(f.home, f.main);
    f.workspace.activeWindow = null;
    f.tick(30000);
    assert.equal(f.main.current, f.home);
});

test("explicit borrow adds a temporary membership and waits for focus loss", () => {
    const f = fixture();
    f.borrow();
    assert.equal(f.main.current, f.here);
    assert.deepEqual(f.app.desktops, [f.home, f.here]);
    assert.deepEqual(f.kitty.desktops, [f.home]);
    f.tick(30000);
    assert.deepEqual(f.app.desktops, [f.home, f.here]);
    f.workspace.activeWindow = null;
    f.tick(30250);
    assert.deepEqual(f.app.desktops, [f.home]);
});

test("a manual reassignment during a borrow takes precedence", () => {
    const f = fixture();
    f.borrow();
    f.app.desktops = [f.other];
    f.workspace.activeWindow = null;
    f.tick(30000);
    assert.deepEqual(f.app.desktops, [f.other]);
});

test("a resize during a borrow still allows the temporary membership to expire", () => {
    const f = fixture();
    f.borrow();
    f.app.interactiveMoveResizeStarted.emit();
    f.workspace.activeWindow = null;
    f.tick(30000);
    assert.deepEqual(f.app.desktops, [f.home]);
});
