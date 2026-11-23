import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// 接続: the transitions of the selected candidate, BOS first and EOS last
// (DESIGN.md §4.2). Same five gestures as a word, but an edit reaches every
// sentence that crosses the same POS pair.
ColumnLayout {
    id: pane
    property var st
    readonly property var rows: st.connections || []
    spacing: 8

    Label {
        Layout.fillWidth: true
        visible: (st.candidates || []).length > 0
        text: qsTr("説明対象: %1").arg(((st.candidates || [])[st.selectedCandidate] || {}).text || "")
        font.pixelSize: 13
    }

    ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: pane.rows
        spacing: 2
        ScrollBar.vertical: ScrollBar {}

        delegate: Rectangle {
            id: row
            required property var modelData
            width: list.width
            height: 42
            radius: Math.min(4, theme.radius)
            color: "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 4
                spacing: 8
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Label {
                        text: row.modelData.left + "  →  " + row.modelData.right
                        font.pixelSize: 14
                        opacity: row.modelData.disabled ? 0.5 : 1
                        font.strikeout: row.modelData.disabled
                    }
                    Label {
                        text: row.modelData.leftPOS + "  →  " + row.modelData.rightPOS
                        font.pixelSize: 10
                        opacity: 0.5
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
                Label {
                    font.family: "monospace"
                    Layout.preferredWidth: 150
                    horizontalAlignment: Text.AlignRight
                    color: row.modelData.userOverride ? Material.accentColor : Material.foreground
                    text: row.modelData.userOverride
                          ? qsTr("%1（元 %2）").arg(row.modelData.cost).arg(row.modelData.baseCost)
                          : String(row.modelData.cost)
                }
                ToolButton { text: qsTr("強める"); onClicked: backend.boostConnection(row.modelData.rid, row.modelData.lid, 1) }
                ToolButton { text: qsTr("弱める"); onClicked: backend.boostConnection(row.modelData.rid, row.modelData.lid, -1) }
                CostField {
                    maximum: pane.st.costMax || 32767
                    onAccepted: (value) => backend.setConnectionCost(row.modelData.rid, row.modelData.lid, value)
                }
                ToolButton {
                    text: row.modelData.disabled ? qsTr("復活") : qsTr("使わない")
                    onClicked: backend.toggleConnectionDisabled(row.modelData.rid, row.modelData.lid, row.modelData.disabled)
                }
                ToolButton {
                    text: qsTr("リセット")
                    enabled: row.modelData.userOverride || row.modelData.disabled
                    onClicked: backend.resetConnection(row.modelData.rid, row.modelData.lid)
                }
            }
        }

        Label {
            anchors.centerIn: parent
            visible: pane.rows.length === 0
            text: qsTr("候補を選ぶと、その境界ごとの接続コストがここに並ぶ")
            opacity: 0.5
        }
    }

    Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        opacity: 0.6
        text: qsTr("編集済みの接続: %1 マス。接続の編集は、同じ品詞の組を通るすべての文に効く。影響は vimeu-eval --user でテストセットに掛けて測る。").arg(st.connectionEditCount || 0)
    }
}
