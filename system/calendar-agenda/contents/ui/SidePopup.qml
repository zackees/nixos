import QtQuick
import org.kde.plasma.core as PlasmaCore

// A window at explicit screen coordinates: to the right of `anchorItem`,
// top edges aligned. Content goes in `mainItem`, as with any Dialog.
//
// Why not PopupPlasmaWindow with popupDirection: Qt.RightEdge: that only
// asks for a side, and the compositor flips the popup to the left whenever
// it judges the space short -- which it did, over the list it was meant to
// sit beside. A Dialog without a visualParent is placed by plasmashell
// itself (plasma-shell protocol on Wayland), so x/y are where it lands.
PlasmaCore.Dialog {
    id: popup
    property Item anchorItem
    property int gap: 6

    location: PlasmaCore.Types.Floating
    flags: Qt.WindowStaysOnTopHint | Qt.WindowDoesNotAcceptFocus
    hideOnWindowDeactivate: false

    function place() {
        if (!anchorItem || !anchorItem.Window.window) return;
        const w = anchorItem.Window.window;
        const p = anchorItem.mapToItem(null, anchorItem.width, 0);
        x = w.x + p.x + gap;
        y = w.y + p.y;
    }
    onVisibleChanged: if (visible) place()
    // A named property, not a child: a Dialog's default property is
    // mainItem, which only takes an Item ("Type SidePopup unavailable").
    property Connections follow: Connections {
        target: popup.anchorItem ? popup.anchorItem.Window.window : null
        function onXChanged() { popup.place(); }
        function onYChanged() { popup.place(); }
        function onWidthChanged() { popup.place(); }
    }
}
