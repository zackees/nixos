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
    property var list_: ({tasks: [], open: 0, synced: true})
    // Done tasks fold away under their own arrow, like the agenda's Done.
    property bool doneOpen: false
    readonly property var openTasks: list_.tasks.filter(t => !t.done)
    readonly property var doneTasks: list_.tasks.filter(t => t.done)
    toolTipMainText: "Tasks"
    toolTipSubText: list_.open + " open" + (list_.synced ? "" : " · not synced")

    readonly property string cli: "@TASKS@"

    function refresh() { lister.disconnectSource(cli + " list"); lister.connectSource(cli + " list"); }
    // Edits run one at a time and refresh the list when done.
    function run(args) { runner.connectSource(cli + " " + args); }

    Plasma5Support.DataSource {
        id: lister
        engine: "executable"
        connectedSources: [root.cli + " list"]
        interval: 30000
        onNewData: function(sourceName, data) {
            if (data["exit code"] !== 0) return;
            try { root.list_ = JSON.parse(data.stdout); } catch (e) { }
        }
    }

    Plasma5Support.DataSource {
        id: runner
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName);
            root.refresh();
        }
    }

    compactRepresentation: MouseArea {
        id: tab
        Layout.minimumWidth: 64
        Layout.preferredWidth: 64
        Accessible.name: "Tasks: " + root.list_.open + " open"
        Accessible.role: Accessible.Button
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

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
                source: "view-task"
                Layout.preferredWidth: 16
                Layout.preferredHeight: 16
            }
            PlasmaComponents.Label {
                text: root.list_.open
                font.pixelSize: 12
                font.bold: true
            }
            // Amber dot: an edit is committed locally but not yet pushed.
            Rectangle {
                visible: !root.list_.synced
                Layout.preferredWidth: 6
                Layout.preferredHeight: 6
                radius: 3
                color: Kirigami.Theme.neutralTextColor
            }
        }
    }

    fullRepresentation: Item {
        implicitWidth: 380
        implicitHeight: Math.min(560, content.implicitHeight + 24)
        Layout.minimumWidth: implicitWidth
        Layout.maximumWidth: implicitWidth
        Layout.minimumHeight: implicitHeight
        Layout.maximumHeight: implicitHeight
        onVisibleChanged: if (visible) { root.refresh(); entry.forceActiveFocus(); }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            RowLayout {
                Layout.fillWidth: true
                Kirigami.Icon { source: "view-task"; Layout.preferredWidth: 26; Layout.preferredHeight: 26 }
                ColumnLayout {
                    spacing: 0
                    PlasmaComponents.Label { text: "Tasks"; font.bold: true; font.pixelSize: 18 }
                    PlasmaComponents.Label {
                        text: root.list_.synced ? "Synced with zackees/tasks" : "Not synced yet. Will retry."
                        opacity: 0.7
                    }
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    text: "Sync now"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: root.run("sync")
                }
                PlasmaComponents.ToolButton {
                    icon.name: "internet-services"
                    text: "Open on GitHub"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: { Qt.openUrlExternally("https://github.com/zackees/tasks/blob/main/TASKS.md"); root.expanded = false; }
                }
            }
            PlasmaComponents.TextField {
                id: entry
                Layout.fillWidth: true
                placeholderText: "Add a task and press Enter"
                onAccepted: {
                    const t = text.trim();
                    if (t === "") return;
                    root.run("add64 " + Qt.btoa(unescape(encodeURIComponent(t))));
                    text = "";
                }
            }
            PlasmaComponents.Label {
                visible: root.list_.tasks.length === 0
                Layout.fillWidth: true
                text: "Nothing to do"
                horizontalAlignment: Text.AlignHCenter
                opacity: 0.7
            }
            PlasmaComponents.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(440, list.implicitHeight)
                contentWidth: availableWidth
                Column {
                    id: list
                    width: parent.width
                    spacing: 2
                    Repeater { model: root.openTasks; delegate: taskRow }
                    PlasmaComponents.ItemDelegate {
                        visible: root.doneTasks.length > 0
                        width: list.width
                        icon.name: root.doneOpen ? "arrow-down" : "arrow-right"
                        text: "Done · " + root.doneTasks.length
                        font.bold: true
                        opacity: 0.8
                        onClicked: root.doneOpen = !root.doneOpen
                    }
                    Repeater { model: root.doneOpen ? root.doneTasks : []; delegate: taskRow }
                }
            }
        }
    }

    Component {
        id: taskRow
        RowLayout {
            required property var modelData
            width: parent ? parent.width : 0
            spacing: 4
            PlasmaComponents.CheckBox {
                checked: modelData.done
                onToggled: root.run("toggle " + modelData.index)
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: modelData.text
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                font.strikeout: modelData.done
                opacity: modelData.done ? 0.55 : 1.0
            }
            PlasmaComponents.ToolButton {
                icon.name: "edit-delete-remove"
                text: "Remove"
                display: QQC2.AbstractButton.IconOnly
                onClicked: root.run("remove " + modelData.index)
            }
        }
    }
}
