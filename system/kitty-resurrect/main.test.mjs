// Unit test for main.js against a mock KWin scripting API.
//   node --test system/kitty-resurrect/main.test.mjs
// The mock rejects any argument that is not one of the *current* outputs the
// way KWin's C++ bridge does ("Could not convert argument 0 ... to
// KWin::LogicalOutput*"). After an output reconfiguration KWin hands scripts
// new LogicalOutput objects, so a wrapper kept from before is no longer one.
// (Named .mjs so configuration.nix's `*.js` copy does not install it.)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const SRC = readFileSync(new URL("./main.js", import.meta.url), "utf8");

function signal() {
    const hs = [];
    const s = (...a) => hs.forEach(h => h(...a));
    s.connect = h => hs.push(h);
    return s;
}

function harness() {
    const desktops = [{ id: "d1" }, { id: "d2" }];
    const mkOutputs = () => [{ name: "DP-1", geometry: { x: 0, y: 0, width: 2560, height: 1440 } }];
    const managed = [];
    const warnings = [];
    const dbus = [];
    const ws = {
        screens: mkOutputs(),
        desktops,
        current: "d1",
        windows: [],
        activeWindow: null,
        currentDesktopChanged: signal(),
        windowAdded: signal(),
        windowRemoved: signal(),
        windowActivated: signal(),
        windowList() { return this.windows.slice(); },
        checkOutput(o, fn) {
            if (!this.screens.includes(o))
                throw new TypeError(`Passing incompatible arguments to C++ function (${fn})`);
        },
        currentDesktopForScreen(o) {
            this.checkOutput(o, "currentDesktopForScreen");
            return desktops.find(d => d.id === this.current);
        },
        rootTile(o, d) {
            this.checkOutput(o, "rootTile");
            const leaf = { tiles: [], manage: w => managed.push(w), parent: null };
            return { tiles: [leaf, leaf, leaf], parent: null, desktop: d };
        },
        sendClientToScreen(w, o) { this.checkOutput(o, "sendClientToScreen"); w.output = o; },
    };
    const kitty = {
        normalWindow: true, transient: false, resourceClass: "kitty",
        internalId: "{w1}", pid: 1, caption: "kitty-resurrect:abc",
        output: ws.screens[0], desktops: [desktops[0]], minimized: false, tile: null,
        frameGeometry: { x: 0, y: 0, width: 10, height: 10 },
        interactiveMoveResizeFinished: signal(), outputChanged: signal(),
        desktopsChanged: signal(), minimizedChanged: signal(), tileChanged: signal(),
        captionChanged: signal(),
    };
    const placement = { output: "DP-1", desktops: ["d2"], tile: [1],
                        x: 5, y: 5, width: 100, height: 100, minimized: false };
    const ctx = {
        workspace: ws,
        console: { log() {}, warn: (...a) => warnings.push(a.join(" ")) },
        print: (...a) => warnings.push(a.join(" ")),
        callDBus(...a) {
            dbus.push(a[3]);
            const cb = a[a.length - 1];
            if (a[3] === "Claim" && typeof cb === "function") cb(JSON.stringify(placement));
        },
        JSON,
    };
    vm.createContext(ctx);
    return { ws, kitty, ctx, managed, warnings, dbus, desktops, mkOutputs };
}

test("pending tile survives an output reconfiguration (main.js:85 TypeError)", () => {
    const h = harness();
    vm.runInContext(SRC, h.ctx);
    // A restored window lands on d2 while d1 is showing: its tile is deferred.
    h.ws.windows.push(h.kitty);
    h.ws.windowAdded(h.kitty);
    assert.equal(h.managed.length, 0, "tile must wait for its desktop");
    // Monitors sleep and wake: KWin replaces every LogicalOutput object.
    h.ws.screens = h.mkOutputs();
    h.ws.current = "d2";
    assert.doesNotThrow(() => h.ws.currentDesktopChanged());
    assert.deepEqual(h.managed, [h.kitty], "tile applied on the re-resolved output");
});

test("pending tile for a vanished output is dropped without a C++ call", () => {
    const h = harness();
    vm.runInContext(SRC, h.ctx);
    h.ws.windows.push(h.kitty);
    h.ws.windowAdded(h.kitty);
    h.ws.screens = [];
    h.ws.current = "d2";
    assert.doesNotThrow(() => h.ws.currentDesktopChanged());
    assert.equal(h.managed.length, 0);
});

test("an exception in a handler is logged once, never thrown into KWin", () => {
    const h = harness();
    vm.runInContext(SRC, h.ctx);
    h.ws.windowList = () => { throw new Error("boom"); };
    assert.doesNotThrow(() => h.ws.currentDesktopChanged());
    assert.doesNotThrow(() => h.ws.windowActivated(h.kitty));
    assert.ok(h.warnings.some(w => /kitty-resurrect.*boom/.test(w)), h.warnings.join("\n"));
});

test("outputs are reported to the service, and again when they change", () => {
    const h = harness();
    h.ws.screensChanged = signal();
    vm.runInContext(SRC, h.ctx);
    const before = h.dbus.filter(m => m === "Outputs").length;
    assert.ok(before >= 1, "reported at startup: " + h.dbus.join(","));
    h.ws.screens = h.mkOutputs();
    h.ws.screensChanged();
    assert.equal(h.dbus.filter(m => m === "Outputs").length, before + 1);
});

test("a workspace that throws everywhere cannot push an exception into KWin", () => {
    const h = harness();
    h.ws.screensChanged = signal();
    vm.runInContext(SRC, h.ctx);
    h.ws.windows.push(h.kitty);
    for (const k of ["windowList", "currentDesktopForScreen", "rootTile", "sendClientToScreen"])
        h.ws[k] = () => { throw new TypeError("Passing incompatible arguments to C++ function"); };
    Object.defineProperty(h.ws, "screens", { get() { throw new TypeError("gone"); } });
    for (const s of ["currentDesktopChanged", "screensChanged", "windowActivated", "windowRemoved", "windowAdded"])
        assert.doesNotThrow(() => h.ws[s](h.kitty), s);
    for (const s of ["outputChanged", "desktopsChanged", "tileChanged", "captionChanged"])
        assert.doesNotThrow(() => h.kitty[s](), s);
});

test("startup without screensChanged (older KWin) does not throw", () => {
    const h = harness();
    assert.doesNotThrow(() => vm.runInContext(SRC, h.ctx));
});
