import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

// TASKS.md as a plain text editor. The tab counts open `- [ ]` lines; the
// popup is the whole file, saved (commit + push) a moment after typing stops.
PlasmoidItem {
    id: root
    preferredRepresentation: compactRepresentation
    property var list_: ({tasks: [], open: 0, synced: true})
    property string text: ""
    // True while the editor holds keystrokes not yet handed to the backend;
    // a refresh must not overwrite them.
    property bool dirty: false
    toolTipMainText: "Tasks"
    toolTipSubText: list_.open + " open" + (list_.synced ? "" : " · not synced")

    readonly property string cli: "@TASKS@"

    function refresh() { lister.disconnectSource(cli + " list"); lister.connectSource(cli + " list"); }
    function load() { reader.disconnectSource(cli + " read"); reader.connectSource(cli + " read"); }
    function save() {
        if (!dirty) return;
        dirty = false;
        saver.connectSource(cli + " save64 " + Qt.btoa(unescape(encodeURIComponent(text))));
    }
    onExpandedChanged: if (expanded) load(); else save()

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
        id: reader
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName);
            if (data["exit code"] !== 0 || root.dirty) return;
            root.text = data.stdout.replace(/\n$/, "");
        }
    }

    Plasma5Support.DataSource {
        id: saver
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName);
            root.refresh();
        }
    }

    Timer {
        id: saveTimer
        interval: 1500
        onTriggered: root.save()
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
        implicitWidth: 560
        implicitHeight: 620
        Layout.minimumWidth: implicitWidth
        Layout.minimumHeight: implicitHeight
        onVisibleChanged: if (visible) editor.forceActiveFocus()

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label { text: "TASKS.md"; font.bold: true; font.pixelSize: 16 }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: root.dirty ? "editing…" : root.list_.synced ? "synced" : "not synced, will retry"
                    opacity: 0.6
                }
                PlasmaComponents.ToolButton {
                    icon.name: "internet-services"
                    text: "Open on GitHub"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: { Qt.openUrlExternally("https://github.com/zackees/tasks/blob/main/TASKS.md"); root.expanded = false; }
                }
            }
            PlasmaComponents.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                QQC2.TextArea {
                    id: editor
                    text: root.text
                    font.family: "monospace"
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    selectByMouse: true
                    onTextChanged: {
                        if (text === root.text) return;
                        root.text = text;
                        root.dirty = true;
                        saveTimer.restart();
                    }
                }
            }
        }
    }
}
