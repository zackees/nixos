import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    readonly property var mediaApps: [
        { name: "Photon Studio", icon: "photon-studio", desktop: "photon-studio.desktop" },
        { name: "Kdenlive", icon: "org.kde.kdenlive", desktop: "org.kde.kdenlive.desktop" },
        { name: "HandBrake", icon: "fr.handbrake.ghb", desktop: "fr.handbrake.ghb.desktop" },
        { name: "OBS Studio (Rust)", icon: "obs-studio-rust", desktop: "obs-studio-rust.desktop" },
        { name: "LosslessCut", icon: "losslesscut", desktop: "losslesscut.desktop" },
        { name: "Glaxnimate", icon: "org.kde.glaxnimate", desktop: "org.kde.glaxnimate.desktop" },
        { name: "VLC", icon: "vlc", desktop: "vlc.desktop" }
    ]

    preferredRepresentation: compactRepresentation
    toolTipMainText: "Media Apps"
    toolTipSubText: "Hover to show media applications"

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

        Kirigami.Icon {
            anchors.fill: parent
            anchors.margins: 2
            source: "folder-videos"
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
                model: root.mediaApps

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
                                               + "/run/current-system/sw/share/applications/"
                                               + modelData.desktop)
                    }
                }
            }
        }
    }
}
