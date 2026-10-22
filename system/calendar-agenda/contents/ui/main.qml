import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root
    preferredRepresentation: compactRepresentation
    property var agenda: ({events: [], next: null, nextLabel: "Calendar", countdown: "Loading…", error: ""})
    readonly property string title: agenda.next ? agenda.next.title : agenda.countdown
    toolTipMainText: ""
    toolTipSubText: ""

    property bool tabHovered: false
    property bool agendaHovered: false

    function updateHover() {
        if (tabHovered || agendaHovered) {
            closeTimer.stop();
            root.expanded = true;
        } else {
            closeTimer.restart();
        }
    }

    Timer {
        id: closeTimer
        interval: 0
        onTriggered: {
            if (!root.tabHovered && !root.agendaHovered) root.expanded = false;
        }
    }

    Plasma5Support.DataSource {
        id: calendar
        engine: "executable"
        connectedSources: ["@AGENDA@"]
        interval: 30000
        onNewData: function(sourceName, data) {
            if (data["exit code"] !== 0) return;
            try { root.agenda = JSON.parse(data.stdout); } catch (e) { }
        }
    }

    Plasma5Support.DataSource {
        id: launcher
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) { disconnectSource(sourceName); }
    }

    compactRepresentation: MouseArea {
        id: tab
        Layout.minimumWidth: 96
        Layout.preferredWidth: 96
        Layout.maximumWidth: 96
        Accessible.name: root.agenda.nextLabel + ": " + root.title
        Accessible.role: Accessible.Button

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 7
            color: Qt.alpha(Kirigami.Theme.highlightColor, tab.containsMouse || root.expanded ? 0.23 : 0.10)
            border.width: 1
            border.color: Qt.alpha(Kirigami.Theme.highlightColor, 0.35)
        }
        RowLayout {
            anchors.centerIn: parent
            spacing: 6
            Kirigami.Icon {
                source: "view-calendar-agenda"
                Layout.preferredWidth: 16
                Layout.preferredHeight: 16
            }
            PlasmaComponents.Label {
                text: root.agenda.next ? Qt.formatDateTime(new Date(root.agenda.next.start * 1000), "h:mm AP") : "—"
                font.pixelSize: 12
                font.bold: true
            }
        }
        // Include the panel padding so the hover region reaches the popup.
        HoverHandler {
            margin: 12
            onHoveredChanged: {
                root.tabHovered = hovered;
                root.updateHover();
            }
        }
        onClicked: { closeTimer.stop(); root.expanded = !root.expanded; }
    }

    fullRepresentation: Item {
        implicitWidth: 440
        implicitHeight: Math.min(520, content.implicitHeight + 24)
        // Include the popup's frame, not just its inner content. Together
        // with the tab's margin this creates a continuous hover handoff.
        HoverHandler {
            margin: 12
            onHoveredChanged: {
                root.agendaHovered = hovered;
                root.updateHover();
            }
        }
        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                Kirigami.Icon {
                    source: "view-calendar-agenda"
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                }
                ColumnLayout {
                    spacing: 0
                    PlasmaComponents.Label { text: "Today's meetings"; font.bold: true; font.pixelSize: 18 }
                    PlasmaComponents.Label {
                        text: root.agenda.date || "Calendar"
                        opacity: 0.7
                        textFormat: Text.PlainText
                    }
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.ToolButton {
                    icon.name: "view-calendar-day"
                    text: "Open calendar"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: launcher.connectSource("/run/current-system/sw/bin/kioclient exec /run/current-system/sw/share/applications/org.kde.korganizer.desktop")
                }
            }
            PlasmaComponents.Label {
                visible: root.agenda.next !== null
                Layout.fillWidth: true
                text: root.agenda.nextLabel + " · " + root.agenda.countdown + " · " + root.title
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Kirigami.Theme.linkColor
            }
            PlasmaComponents.Label {
                visible: root.agenda.events.length === 0
                Layout.fillWidth: true
                text: root.agenda.error || "No meetings scheduled today."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                padding: 12
            }
            PlasmaComponents.ScrollView {
                visible: root.agenda.events.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(420, eventList.implicitHeight)
                contentWidth: availableWidth
                Column {
                    id: eventList
                    width: parent.width
                    spacing: 6
                    Repeater {
                        model: root.agenda.events
                        delegate: PlasmaComponents.ItemDelegate {
                            id: meeting
                            required property var modelData
                            width: eventList.width
                            implicitHeight: details.implicitHeight + 18
                            enabled: true
                            opacity: modelData.status === "past" ? 0.5 : 1.0
                            highlighted: modelData.status === "current"
                            onClicked: {
                                if (modelData.url) Qt.openUrlExternally(modelData.url);
                            }
                            contentItem: ColumnLayout {
                                id: details
                                spacing: 4
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: (meeting.modelData.status === "current" ? "NOW · " : "") + meeting.modelData.time
                                    textFormat: Text.PlainText
                                    font.bold: true
                                    color: meeting.modelData.status === "current" ? Kirigami.Theme.linkColor : Kirigami.Theme.textColor
                                }
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: meeting.modelData.title
                                    textFormat: Text.PlainText
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: 14
                                }
                                PlasmaComponents.Label {
                                    visible: meeting.modelData.linkKind !== "" || meeting.modelData.location !== ""
                                    Layout.fillWidth: true
                                    text: meeting.modelData.linkKind === "Zoom" ? "Zoom · Click to join" : meeting.modelData.location || "Open calendar event"
                                    textFormat: Text.PlainText
                                    wrapMode: Text.WordWrap
                                    opacity: 0.7
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
