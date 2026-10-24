import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root
    preferredRepresentation: compactRepresentation
    property var agenda: ({events: [], done: [], tomorrow: [], next: null, next_label: "Calendar", countdown: "Loading…", error: ""})
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

    // The Done section's arrow. Closed during the day so what is still ahead
    // leads; once nothing is ahead the section opens regardless.
    property bool doneOpen: false
    readonly property bool showDone: doneOpen || agenda.events.length === 0

    property bool tabHovered: false
    // The meeting whose full details slide out to the right of the list.
    property var focusRow: null
    // With nothing hovered yet, show the meeting the tab shows.
    readonly property var shownRow: focusRow || agenda.next
        || (agenda.events.length > 0 ? agenda.events[0] : null)
        || (agenda.done.length > 0 ? agenda.done[agenda.done.length - 1] : null)
        || (agenda.tomorrow && agenda.tomorrow.length > 0 ? agenda.tomorrow[0] : null)
    onExpandedChanged: if (!expanded) focusRow = null

    function escapeHtml(text) {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }
    function link(href, label) {
        return '<a href="' + escapeHtml(href) + '">' + escapeHtml(label) + '</a>';
    }
    // Everything known about a meeting, with its Zoom link, emails and phones clickable.
    function fullDetails(row) {
        const parts = ["<b>" + escapeHtml(row.title) + "</b>", escapeHtml(row.time)];
        if (row.location !== "" && row.link_kind !== "Zoom") parts.push(escapeHtml(row.location));
        if (row.link_kind === "Zoom") parts.push(link("zoom:", "Join Zoom meeting"));
        const contacts = row.emails.map(a => link("mailto:" + a, a))
            .concat(row.phones.map(n => link("tel:" + n.replace(/[^\d+]/g, ""), n)));
        if (contacts.length > 0) parts.push(contacts.join("<br>"));
        if (row.details !== "") parts.push(escapeHtml(row.details).replace(/\n/g, "<br>"));
        return parts.join("<br><br>");
    }
    property bool agendaHovered: false
    property bool detailsHovered: false

    function updateHover() {
        if (tabHovered || agendaHovered || detailsHovered) {
            closeTimer.stop();
            root.expanded = true;
        } else {
            closeTimer.restart();
        }
    }

    Timer {
        id: closeTimer
        // Long enough to cross from the list into the details popup, a separate window.
        interval: 150
        onTriggered: {
            if (!root.tabHovered && !root.agendaHovered && !root.detailsHovered) root.expanded = false;
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
        id: fullRep
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
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: 12
            width: 416
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
                HoverHandler { onHoveredChanged: if (hovered) root.focusRow = root.agenda.next }
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
                        text: root.agenda.next && !root.agenda.live ? "Next up: " + root.title : root.title
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
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
                visible: root.agenda.events.length === 0 && root.agenda.done.length === 0
                Layout.fillWidth: true
                text: root.agenda.error || "No meetings scheduled today."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                padding: 12
            }
            PlasmaComponents.ScrollView {
                visible: root.agenda.events.length > 0 || root.agenda.done.length > 0 || root.agenda.tomorrow.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(420, eventList.implicitHeight)
                contentWidth: availableWidth
                Column {
                    id: eventList
                    width: parent.width
                    spacing: 6
                    Repeater {
                        model: root.agenda.events
                        delegate: meetingRow
                    }
                    PlasmaComponents.ItemDelegate {
                        visible: root.agenda.done.length > 0
                        width: eventList.width
                        icon.name: root.showDone ? "arrow-down" : "arrow-right"
                        text: "Done · " + root.agenda.done.length
                        font.bold: true
                        opacity: 0.8
                        // Nothing ahead: the done list is all there is, so keep it open.
                        enabled: root.agenda.events.length > 0
                        onClicked: root.doneOpen = !root.doneOpen
                    }
                    Repeater {
                        model: root.showDone ? root.agenda.done : []
                        delegate: meetingRow
                    }
                    // Once today is over, look ahead; these rows are green.
                    PlasmaComponents.Label {
                        visible: root.agenda.tomorrow.length > 0
                        width: eventList.width
                        topPadding: 8
                        text: "Tomorrow"
                        font.bold: true
                        color: Kirigami.Theme.positiveTextColor
                    }
                    Repeater {
                        model: root.agenda.tomorrow
                        delegate: meetingRow
                    }
                }
            }
        }
        // Hovering a meeting opens its full details in a second popup on the
        // right. Widening this popup instead does not work: the panel is
        // centred, so Plasma centres the popup on the tab and the list would
        // move left as the popup grew.
        PlasmaCore.PopupPlasmaWindow {
            id: slideOut
            visualParent: fullRep
            popupDirection: Qt.RightEdge
            visible: root.expanded && root.focusRow !== null
            hideOnWindowDeactivate: false
            mainItem: Item {
                width: 380
                height: Math.max(fullRep.height, 200)
                HoverHandler {
                    margin: 12
                    onHoveredChanged: {
                        root.detailsHovered = hovered;
                        root.updateHover();
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: Qt.alpha(Kirigami.Theme.highlightColor, 0.08)
                    border.width: 1
                    border.color: Qt.alpha(Kirigami.Theme.highlightColor, 0.35)
                    PlasmaComponents.ScrollView {
                        anchors.fill: parent
                        anchors.margins: 12
                        contentWidth: availableWidth
                        PlasmaComponents.Label {
                            width: parent ? parent.width : 0
                            text: root.shownRow ? root.fullDetails(root.shownRow) : ""
                            textFormat: Text.StyledText
                            wrapMode: Text.Wrap
                            linkColor: Kirigami.Theme.linkColor
                            onLinkActivated: function(href) {
                                if (href === "zoom:") {
                                    root.openMeeting(root.shownRow);
                                } else {
                                    Qt.openUrlExternally(href);
                                    root.expanded = false;
                                }
                            }
                            HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: meetingRow
        PlasmaComponents.ItemDelegate {
            id: meeting
            required property var modelData
            // Tomorrow's meetings read in green, apart from today's.
            readonly property color accent: modelData.tomorrow ? Kirigami.Theme.positiveTextColor
                : modelData.status === "current" ? Kirigami.Theme.linkColor : Kirigami.Theme.textColor
            width: parent ? parent.width : 0
            implicitHeight: details.implicitHeight + 18
            enabled: true
            opacity: modelData.status === "past" ? 0.5 : 1.0
            highlighted: modelData.status === "current"
            onClicked: root.openMeeting(modelData)

            onHoveredChanged: if (hovered) root.focusRow = modelData

            contentItem: ColumnLayout {
                id: details
                spacing: 4
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: (meeting.modelData.status === "current" ? "NOW · " : "") + meeting.modelData.time
                    textFormat: Text.PlainText
                    font.bold: true
                    color: meeting.accent
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: meeting.modelData.title
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.pixelSize: 14
                    color: meeting.modelData.tomorrow ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
                }
                PlasmaComponents.Label {
                    visible: meeting.modelData.link_kind !== "Zoom"
                        && (meeting.modelData.link_kind !== "" || meeting.modelData.location !== "")
                    Layout.fillWidth: true
                    text: meeting.modelData.location || "Open calendar event"
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    opacity: 0.7
                }
                // The Zoom link, drawn as a hyperlink; it joins in the app.
                RowLayout {
                    visible: meeting.modelData.link_kind === "Zoom"
                    Layout.fillWidth: true
                    spacing: 4
                    Kirigami.Icon {
                        source: "camera-video"
                        Layout.preferredWidth: 14
                        Layout.preferredHeight: 14
                    }
                    PlasmaComponents.Label {
                        id: zoomLink
                        Layout.fillWidth: true
                        // Drop the query string: it can carry the meeting passcode.
                        text: meeting.modelData.url.replace(/^https?:\/\//, "").split("?")[0]
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Kirigami.Theme.linkColor
                        font.underline: true
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openMeeting(meeting.modelData)
                        }
                    }
                }
                Repeater {
                    model: meeting.modelData.emails.map(address => ({label: address, href: "mailto:" + address}))
                        .concat(meeting.modelData.phones.map(number => ({label: number, href: "tel:" + number.replace(/[^\d+]/g, "")})))
                    delegate: PlasmaComponents.Label {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData.label
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Kirigami.Theme.linkColor
                        font.underline: true
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                Qt.openUrlExternally(parent.modelData.href);
                                root.expanded = false;
                            }
                        }
                    }
                }
            }
        }
    }
}
