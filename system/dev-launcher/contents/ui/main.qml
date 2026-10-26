import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    // `desktop` is a full path, which the media launcher does not assume.
    // Hermes has two rows, desktop app and web view, so the choice costs no
    // extra click; `listOnly` keeps the web row out of the panel icon grid.
    readonly property var devApps: [
        { name: "Visual Studio Code", icon: "vscode",
          desktop: "/run/current-system/sw/share/applications/code.desktop" },
        { name: "Hermes", icon: "/run/current-system/sw/share/icons/hicolor/1024x1024/apps/hermes.png",
          desktop: "/run/current-system/sw/share/applications/hermes-launcher.desktop" },
        { name: "Hermes Web", icon: "pyweb-view.hermes", listOnly: true,
          desktop: "/home/niteris/.local/share/applications/pyweb-view.hermes.desktop" }
    ]

    preferredRepresentation: compactRepresentation
    toolTipMainText: "Dev"
    toolTipSubText: "Visual Studio Code, Hermes, Hermes Web"

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
                model: root.devApps.filter(app => !app.listOnly)
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
                model: root.devApps

                delegate: PlasmaComponents.ItemDelegate {
                    required property var modelData
                    width: appList.width
                    height: 40
                    text: modelData.name
                    // icon.name takes only theme names; Hermes's icon is a file.
                    icon.name: modelData.icon.startsWith("/") ? "" : modelData.icon
                    icon.source: modelData.icon.startsWith("/") ? "file://" + modelData.icon : ""

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
