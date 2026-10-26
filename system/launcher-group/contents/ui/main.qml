import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

// One dock folder: a 2x2 icon grid that opens a list on hover. The name and
// the apps come from mkLauncherGroup in system/configuration.nix.
PlasmoidItem {
    id: root

    // [{name, icon, desktop}]; `desktop` is a full path to a .desktop file.
    readonly property var apps: @APPS@

    preferredRepresentation: compactRepresentation
    toolTipMainText: "@NAME@"
    toolTipSubText: apps.map(app => app.name).join(", ")

    Timer {
        id: closeTimer
        interval: 450
        onTriggered: root.expanded = false
    }

    Plasma5Support.DataSource {
        id: launcher
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
        }
    }

    compactRepresentation: MouseArea {
        Layout.minimumWidth: height
        Layout.preferredWidth: height
        hoverEnabled: true

        Grid {
            anchors.centerIn: parent
            columns: 2
            spacing: 1
            Repeater {
                model: root.apps.slice(0, 4)
                Kirigami.Icon {
                    required property var modelData
                    width: (parent.parent.height - 5) / 2
                    height: width
                    source: modelData.icon
                }
            }
        }

        onEntered: {
            closeTimer.stop()
            root.expanded = true
        }
        onExited: closeTimer.restart()
        onClicked: {
            closeTimer.stop()
            root.expanded = true
        }
    }

    fullRepresentation: Item {
        implicitWidth: 270
        implicitHeight: appList.implicitHeight + 16

        HoverHandler {
            onHoveredChanged: {
                if (hovered) {
                    closeTimer.stop()
                } else {
                    closeTimer.restart()
                }
            }
        }

        Column {
            id: appList
            anchors.fill: parent
            anchors.margins: 8
            spacing: 2

            Repeater {
                model: root.apps

                delegate: PlasmaComponents.ItemDelegate {
                    required property var modelData
                    width: appList.width
                    height: 40
                    text: modelData.name
                    icon.name: modelData.icon

                    onClicked: {
                        closeTimer.stop()
                        root.expanded = false
                        launcher.connectSource("/run/current-system/sw/bin/kioclient exec "
                                               + modelData.desktop)
                    }
                }
            }
        }
    }
}
