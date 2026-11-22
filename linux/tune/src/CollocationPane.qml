import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// 共起: word pairs the user defines (DESIGN.md §3.5). The menus only offer
// content words of the current candidates, so a pair that could never fire
// cannot be registered.
ColumnLayout {
    id: pane
    property var st
    readonly property var choices: st.collocationChoices || []
    readonly property var pairs: st.collocations || []
    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        ComboBox {
            id: polarity
            model: [qsTr("正の共起（同時に選びたい）"), qsTr("負の共起（同時に出したくない）")]
            Layout.preferredWidth: 260
        }
        ComboBox { id: left; model: pane.choices; Layout.preferredWidth: 160 }
        Label { text: polarity.currentIndex === 0 ? "→" : "↔"; font.pixelSize: 18 }
        ComboBox {
            id: right
            model: pane.choices
            Layout.preferredWidth: 160
            Component.onCompleted: if (count > 1) currentIndex = 1
            onModelChanged: if (count > 1 && currentIndex === left.currentIndex) currentIndex = (left.currentIndex + 1) % count
        }
        Button {
            text: qsTr("組を追加")
            enabled: left.currentText.length > 0 && right.currentText.length > 0 && left.currentText !== right.currentText
            onClicked: backend.addCollocation(left.currentText, right.currentText, polarity.currentIndex === 1)
        }
        Item { Layout.fillWidth: true }
    }

    Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        opacity: 0.6
        text: polarity.currentIndex === 0
              ? qsTr("組を満たす候補が %1 だけ安くなる。効くのはトップから %1 以内の候補だけ。組を登録すると変換は遅くなる。").arg(st.collocationBonus || 3453)
              : qsTr("2 語を同時に含む候補は、コストに関係なく除外される。語順は問わない。")
    }

    ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: pane.pairs
        spacing: 2
        ScrollBar.vertical: ScrollBar {}

        delegate: Rectangle {
            id: row
            required property var modelData
            width: list.width
            height: 40
            radius: Math.min(4, theme.radius)
            color: modelData.active ? "#1f1f26" : "transparent"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 4
                spacing: 12
                Label {
                    text: row.modelData.left + (row.modelData.negative ? "  ↔  " : "  →  ") + row.modelData.right
                    font.pixelSize: 17
                }
                Label {
                    text: row.modelData.negative ? qsTr("負の共起") : qsTr("正の共起")
                    opacity: 0.6
                }
                Label {
                    visible: row.modelData.active
                    text: qsTr("この読みの候補に効いている")
                    color: Material.accentColor
                }
                Item { Layout.fillWidth: true }
                ToolButton { text: qsTr("削除"); onClicked: backend.removeCollocation(row.modelData.left, row.modelData.right) }
            }
        }

        Label {
            anchors.centerIn: parent
            visible: pane.pairs.length === 0
            text: qsTr("登録した組がここに並ぶ")
            opacity: 0.5
        }
    }
}
