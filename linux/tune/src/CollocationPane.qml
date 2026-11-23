import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// 共起: word pairs the user defines (DESIGN.md §3.5). The menus only offer
// content words of the candidate selected in the candidate list (not every
// candidate — the pooled list was too long to pick from), so a pair that
// could never fire cannot be registered.
ColumnLayout {
    id: pane
    property var st
    readonly property var choices: st.collocationChoices || []
    readonly property var pairs: st.collocations || []
    spacing: 8

    // A choice the user made survives a model change (another candidate
    // selected, an edit re-converting) as long as the word is still there;
    // otherwise the menu falls back, as AdjustmentViewModel does on macOS.
    // Deferred so both menus have taken the new model first.
    onChoicesChanged: Qt.callLater(syncMenus)
    Component.onCompleted: syncMenus()
    function syncMenus() {
        const l = choices.indexOf(leftMenu.kept)
        leftMenu.currentIndex = l >= 0 ? l : (choices.length > 0 ? 0 : -1)
        leftMenu.kept = leftMenu.currentText
        let r = choices.indexOf(rightMenu.kept)
        if (r < 0) r = choices.findIndex(w => w !== leftMenu.currentText)
        rightMenu.currentIndex = r
        rightMenu.kept = rightMenu.currentText
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        ComboBox {
            id: polarity
            model: [qsTr("正の共起（同時に選びたい）"), qsTr("負の共起（同時に出したくない）")]
            Layout.preferredWidth: 260
        }
        ComboBox {
            id: leftMenu
            property string kept: ""
            model: pane.choices
            visible: count > 0
            Layout.preferredWidth: 160
            onActivated: kept = currentText
        }
        Label { visible: leftMenu.visible; text: polarity.currentIndex === 0 ? "→" : "↔"; font.pixelSize: 15 }
        ComboBox {
            id: rightMenu
            property string kept: ""
            model: pane.choices
            visible: count > 0
            Layout.preferredWidth: 160
            onActivated: kept = currentText
        }
        Label {
            visible: pane.choices.length === 0
            text: qsTr("候補を選ぶと、その候補に含まれる自立語がここから選べます。")
            opacity: 0.6
        }
        Button {
            visible: leftMenu.visible
            text: qsTr("組を追加")
            enabled: leftMenu.currentText.length > 0 && rightMenu.currentText.length > 0 && leftMenu.currentText !== rightMenu.currentText
            onClicked: backend.addCollocation(leftMenu.currentText, rightMenu.currentText, polarity.currentIndex === 1)
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
            height: 32
            radius: Math.min(4, theme.radius)
            color: modelData.active ? "#1f1f26" : "transparent"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 4
                spacing: 12
                Label {
                    text: row.modelData.left + (row.modelData.negative ? "  ↔  " : "  →  ") + row.modelData.right
                    font.pixelSize: 14
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
