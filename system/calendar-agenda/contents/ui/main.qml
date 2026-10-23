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
    property var agenda: ({events: [], next: null, next_label: "Calendar", countdown: "Loading…", error: ""})
    readonly property string title: agenda.next ? agenda.next.title : agenda.countdown

    // Open a meeting: straight into the Zoom app when there is a join URL,
    // otherwise its web link. Close the agenda so the meeting is in front.
    function openMeeting(row) {
        const url = row.join_url || row.url;
        if (!url) return;
        Qt.openUrlExternally(url);
        root.expanded = false;
    }
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
        // One slot is roughly the clock's width; a close follow-on meeting
        // doubles the tab rather than squeezing a second time into it.
        readonly property int tabWidth: root.agenda.following ? 224 : 112
        Layout.minimumWidth: tabWidth
        Layout.preferredWidth: tabWidth
        Layout.maximumWidth: tabWidth
        Accessible.name: root.agenda.next_label + ": " + root.title
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
            spacing: 5
            Kirigami.Icon {
                source: "view-calendar-agenda"
                Layout.preferredWidth: 16
                Layout.preferredHeight: 16
            }
            // The selected meeting is happening now; it stays until it ends.
            Rectangle {
                visible: root.agenda.live === true
                Layout.preferredWidth: 7
                Layout.preferredHeight: 7
                radius: 3.5
                color: "#e5322d"
            }
            PlasmaComponents.Label {
                text: root.agenda.live ? "In progress"
                    : root.agenda.next ? Qt.formatDateTime(new Date(root.agenda.next.start * 1000), "h:mm AP") : "—"
                font.pixelSize: 12
                font.bold: true
            }
            // The back-to-back meeting after the live one.
            Rectangle {
                visible: !!root.agenda.following
                Layout.preferredWidth: 1
                Layout.preferredHeight: 16
                Layout.leftMargin: 6
                Layout.rightMargin: 6
                color: Qt.alpha(Kirigami.Theme.textColor, 0.35)
            }
            PlasmaComponents.Label {
                visible: !!root.agenda.following
                text: root.agenda.following ? "Next " + Qt.formatDateTime(new Date(root.agenda.following.start * 1000), "h:mm AP") : ""
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
            // Headliner: the meeting the tab shows, with one big Join button.
            Rectangle {
                visible: root.agenda.next !== null
                Layout.fillWidth: true
                implicitHeight: headliner.implicitHeight + 24
                radius: 8
                color: Qt.alpha(Kirigami.Theme.highlightColor, 0.16)
                border.width: 1
                border.color: Qt.alpha(Kirigami.Theme.highlightColor, 0.45)
                ColumnLayout {
                    id: headliner
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 6
                    RowLayout {
                        spacing: 6
                        Rectangle {
                            visible: root.agenda.live === true
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 8
                            radius: 4
                            color: "#e5322d"
                        }
                        PlasmaComponents.Label {
                            text: root.agenda.live ? "In progress" : root.agenda.next_label + " · " + root.agenda.countdown
                            textFormat: Text.PlainText
                            font.bold: true
                            color: Kirigami.Theme.linkColor
                        }
                    }
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        text: root.title
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        font.pixelSize: 20
                        font.bold: true
                    }
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        text: root.agenda.next ? root.agenda.next.time : ""
                        textFormat: Text.PlainText
                        opacity: 0.75
                    }
                    PlasmaComponents.Button {
                        visible: !!root.agenda.next && root.agenda.next.link_kind === "Zoom"
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        icon.name: "camera-video"
                        text: root.agenda.live ? "Join Zoom meeting now" : "Join Zoom meeting"
                        font.pixelSize: 15
                        font.bold: true
                        highlighted: true
                        onClicked: root.openMeeting(root.agenda.next)
                    }
                }
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
                            onClicked: root.openMeeting(modelData)
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
                                    visible: meeting.modelData.link_kind !== "" || meeting.modelData.location !== ""
                                    Layout.fillWidth: true
                                    text: meeting.modelData.link_kind === "Zoom" ? "Zoom · Click to join" : meeting.modelData.location || "Open calendar event"
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
