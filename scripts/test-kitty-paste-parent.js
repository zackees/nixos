// Run: nix shell nixpkgs#nodejs --command node scripts/test-kitty-paste-parent.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../home/kitty/paste.py'), 'utf8');
const code = source.match(/KWIN_CODE = '''([\s\S]*?)'''/)[1];
function signal() {
    const handlers = [];
    return {connect: f => handlers.push(f), emit: (...args) => handlers.forEach(f => f(...args))};
}
function window(extra = {}) {
    return Object.assign({normalWindow: true, pid: 77, captionNormal: 'source',
        resourceClass: '', desktops: ['desk2'], activities: [], output: 'screen2',
        minimized: false, frameGeometry: {x: 1000, y: 400, width: 1000, height: 600},
        closed: signal(), frameGeometryChanged: signal(), desktopsChanged: signal(),
        activitiesChanged: signal(), minimizedChanged: signal(), closeWindow() {this.wasClosed = true;}
    }, extra);
}
function fixture(ambiguous = false) {
    const parent = window();
    const popup = window({resourceClass: 'kittypaste-test', desktops: ['desk1'], output: 'screen1',
        frameGeometry: {x: 0, y: 0, width: 200, height: 100}});
    const windows = ambiguous ? [parent, window()] : [parent];
    const workspace = {activeWindow: parent, windowList: () => windows,
        windowAdded: signal(), windowActivated: signal(),
        sendClientToScreen: (w, output) => {w.output = output;}};
    const spec = {pid: 77, title: 'source', token: 'KittyPaste-test'};
    vm.runInNewContext(code.replace('__SPEC__', JSON.stringify(spec)), {workspace});
    windows.push(popup);
    workspace.windowAdded.emit(popup);
    return {parent, popup, workspace, windows};
}
{
    const {parent, popup, workspace, windows} = fixture();
    assert.equal(popup.frameGeometry.x, 1400);
    assert.equal(popup.frameGeometry.y, 650);
    assert.equal(popup.output, parent.output);
    assert.deepEqual([...popup.desktops], ['desk2']);
    assert.equal(popup.keepAbove, true);
    workspace.activeWindow = window({pid: 999});
    workspace.windowActivated.emit();
    assert.equal(popup.keepAbove, false);
    parent.frameGeometry.x = 2000;
    parent.desktops = ['desk3'];
    parent.frameGeometryChanged.emit();
    assert.equal(popup.frameGeometry.x, 2400);
    assert.deepEqual([...popup.desktops], ['desk3']);
    parent.minimized = true;
    parent.minimizedChanged.emit();
    assert.equal(popup.minimized, true);
    windows.splice(windows.indexOf(parent), 1);
    workspace.windowActivated.emit();
    assert.equal(popup.wasClosed, true);
}
assert.equal(fixture(true).popup.wasClosed, true);
{
    const {parent, popup} = fixture();
    parent.closed.emit();
    assert.equal(popup.wasClosed, true);
}
console.log('Issue #17: centering, output, desktop, movement, stacking, minimization, closure and ambiguity passed');
