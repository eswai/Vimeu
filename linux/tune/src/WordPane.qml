import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// 単語: every dictionary entry the candidates use, cheapest first.
ColumnLayout {
    id: pane
    property var st
    readonly property var words: st.words || []
    readonly property int step: st.costStep || 500
    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Label { text: qsTr("辞書に無い語を追加"); opacity: 0.7 }
        TextField { id: addReading; placeholderText: qsTr("読み"); text: st.reading || ""; Layout.preferredWidth: 160 }
        TextField { id: addSurface; placeholderText: qsTr("表記"); Layout.preferredWidth: 160 }
        SpinBox { id: addCost; from: 0; to: st.costMax || 32767; value: 1000; stepSize: pane.step; editable: true }
        Button {
            text: qsTr("追加")
            enabled: addReading.text.length > 0 && addSurface.text.length > 0
            onClicked: if (backend.addWord(addReading.text, addSurface.text, addCost.value)) addSurface.text = ""
        }
        Item { Layout.fillWidth: true }
        Label { text: qsTr("強める = コスト −%1").arg(pane.step); opacity: 0.5 }
    }

    ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: pane.words
        spacing: 2
        ScrollBar.vertical: ScrollBar {}

        delegate: Rectangle {
            id: row
            required property var modelData
            width: list.width
            height: 46
            radius: Math.min(4, theme.radius)
            color: modelData.inSelected ? "#1f1f26" : "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 4
                spacing: 8

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Label {
                        text: row.modelData.surface + (row.modelData.ambiguous ? "（" + row.modelData.reading + "）" : "")
                        font.pixelSize: 17
                        font.strikeout: row.modelData.deleted
                        font.bold: row.modelData.inSelected
                        opacity: row.modelData.deleted ? 0.5 : 1
                    }
                    Label {
                        text: row.modelData.pos || qsTr("ユーザー追加語")
                        font.pixelSize: 11
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
                    text: row.modelData.userOverride && row.modelData.baseCost !== null && row.modelData.baseCost !== undefined
                          ? qsTr("%1（元 %2）").arg(row.modelData.cost).arg(row.modelData.baseCost)
                          : String(row.modelData.cost)
                }
                ToolButton { text: qsTr("強める"); onClicked: backend.boostWord(row.modelData.reading, row.modelData.surface, 1) }
                ToolButton { text: qsTr("弱める"); onClicked: backend.boostWord(row.modelData.reading, row.modelData.surface, -1) }
                CostField {
                    maximum: pane.st.costMax || 32767
                    onAccepted: (value) => backend.setWordCost(row.modelData.reading, row.modelData.surface, value)
                }
                ToolButton {
                    text: row.modelData.deleted ? qsTr("復活") : qsTr("削除")
                    onClicked: backend.toggleWordDeleted(row.modelData.reading, row.modelData.surface, row.modelData.deleted)
                }
                ToolButton {
                    text: qsTr("リセット")
                    enabled: row.modelData.userOverride || row.modelData.deleted
                    onClicked: backend.resetWord(row.modelData.reading, row.modelData.surface)
                }
            }
        }

        Label {
            anchors.centerIn: parent
            visible: pane.words.length === 0
            text: qsTr("候補に使われている語がここに並ぶ")
            opacity: 0.5
        }
    }
}
