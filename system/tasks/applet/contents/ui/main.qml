import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

// TASKS.md as a plain text editor. The tab counts open `- [ ]` lines; the
// popup is the whole file, committed locally a moment after typing stops;
// the tasks-sync timer pushes it four times a day.
PlasmoidItem {
    id: root
    preferredRepresentation: compactRepresentation
    property var list_: ({tasks: [], open: 0, synced: true})
    property string text: ""
    // True while the editor holds keystrokes not yet handed to the backend;
    // a refresh must not overwrite them.
    property bool dirty: false
    // The applet's own tooltip cannot take the pointer, so it is off and the
    // tab carries an interactive ToolTipArea instead: move into the popup and
    // click it to open the editor.
    toolTipMainText: ""
    toolTipSubText: ""
    // Hover: the file's top-level list items, as markdown-it parsed them.
    readonly property string topRich: {
        const top = list_.top || [];
        const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        const rows = top.map(i => (i.check === null ? "• " : i.check ? "☑ " : "☐ ")
            + (i.check ? "<s>" + esc(i.text) + "</s>" : esc(i.text)));
        return (rows.length ? rows.join("<br>") : "Nothing yet")
            + (list_.synced ? "" : "<br><i>edits waiting for the next sync</i>");
    }

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

    compactRepresentation: PlasmaCore.ToolTipArea {
      id: tip
      Layout.minimumWidth: 64
      Layout.preferredWidth: 64
      interactive: true
      active: !root.expanded
      mainItem: MouseArea {
        implicitWidth: Math.min(Math.max(tipText.implicitWidth, 240), 520) + 24
        implicitHeight: tipColumn.implicitHeight + 24
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { tip.hideImmediately(); root.expanded = true; }
        ColumnLayout {
            id: tipColumn
            anchors.fill: parent
            anchors.margins: 12
            spacing: 6
            Kirigami.Heading { text: "Tasks"; level: 4 }
            PlasmaComponents.Label {
                id: tipText
                Layout.fillWidth: true
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                text: root.topRich
            }
            PlasmaComponents.Label {
                text: "Click to edit"
                opacity: 0.6
                font.italic: true
            }
        }
      }
      MouseArea {
        id: tab
        anchors.fill: parent
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
            // Amber dot: edits committed locally, waiting for the next sync.
            Rectangle {
                visible: !root.list_.synced
                Layout.preferredWidth: 6
                Layout.preferredHeight: 6
                radius: 3
                color: Kirigami.Theme.neutralTextColor
            }
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
                    text: root.dirty ? "editing…" : root.list_.synced ? "synced" : "saved, syncs at 0/6/12/18h"
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
