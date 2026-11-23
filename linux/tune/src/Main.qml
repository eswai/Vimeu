import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: win
    width: 1100
    height: 760
    minimumWidth: 720
    minimumHeight: 520
    visible: true
    title: qsTr("vimeu 調整")
    color: "#0e0e10"

    Material.theme: Material.Dark
    Material.accent: theme.accent
    Material.roundedScale: theme.radius
    // Base size for every control and label; the fixed sizes below are set
    // relative to it (Material's own default is 14px).
    font.pixelSize: 13

    property bool helpVisible: false
    readonly property var st: backend.state
    readonly property var candidates: st.candidates || []

    function selectCandidate(i) {
        if (i >= 0 && i < candidates.length) backend.selectCandidate(i)
    }

    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; onActivated: win.helpVisible = !win.helpVisible }
    Shortcut { sequences: ["Q", StandardKey.Quit]; context: Qt.ApplicationShortcut; onActivated: Qt.quit() }
    Shortcut { sequences: ["/", "Ctrl+L"]; context: Qt.ApplicationShortcut; onActivated: { readingField.forceActiveFocus(); readingField.selectAll() } }
    Shortcut { sequences: ["J", "Down"]; context: Qt.ApplicationShortcut; enabled: !readingField.activeFocus; onActivated: win.selectCandidate(st.selectedCandidate + 1) }
    Shortcut { sequences: ["K", "Up"]; context: Qt.ApplicationShortcut; enabled: !readingField.activeFocus; onActivated: win.selectCandidate(st.selectedCandidate - 1) }
    Shortcut { sequence: "Ctrl+1"; context: Qt.ApplicationShortcut; onActivated: tabs.currentIndex = 0 }
    Shortcut { sequence: "Ctrl+2"; context: Qt.ApplicationShortcut; onActivated: tabs.currentIndex = 1 }
    Shortcut { sequence: "Ctrl+3"; context: Qt.ApplicationShortcut; onActivated: tabs.currentIndex = 2 }

    Connections {
        target: backend
        function onRaiseRequested() { win.raise(); win.requestActivate() }
    }

    Item {
        anchors.fill: parent
        LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
        LayoutMirroring.childrenInherit: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                TextField {
                    id: readingField
                    Layout.fillWidth: true
                    font.pixelSize: 16
                    placeholderText: qsTr("読み（ひらがな、またはローマ字で入力して Enter）")
                    text: st.reading || ""
                    onAccepted: backend.setReading(text)
                    Component.onCompleted: if (!st.reading) forceActiveFocus()
                }
                Label {
                    text: qsTr("? でキー操作")
                    opacity: 0.5
                }
            }

            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                text: backend.error || st.message || ""
                color: "#ff6b6b"
                wrapMode: Text.Wrap
            }

            // ── 候補（常時表示） ──────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Label { text: qsTr("候補"); font.bold: true }
                Label {
                    text: candidates.length > 0 ? (st.candidateCount > candidates.length ? qsTr("%1 件（上位 %2 件を表示）。行を選ぶと「接続」の説明対象になる").arg(st.candidateCount).arg(candidates.length) : qsTr("%1 件。行を選ぶと「接続」の説明対象になる").arg(candidates.length)) : ""
                    opacity: 0.6
                }
                Item { Layout.fillWidth: true }
                Label { text: qsTr("合計 = 単語 + 接続 + 共起（小さいほど優先）"); opacity: 0.6 }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(140, win.height * 0.28)
                color: "#16161a"
                radius: theme.radius

                ListView {
                    id: candidateList
                    anchors.fill: parent
                    anchors.margins: 4
                    clip: true
                    model: candidates
                    currentIndex: st.selectedCandidate || 0
                    highlightFollowsCurrentItem: false
                    ScrollBar.vertical: ScrollBar {}
                    // After a re-convert the list starts at the top unless the
                    // selection lies beyond the first screenful.
                    function reveal() {
                        if ((currentIndex + 1) * 34 <= height) positionViewAtBeginning()
                        else positionViewAtIndex(currentIndex, ListView.Contain)
                    }
                    onCurrentIndexChanged: Qt.callLater(reveal)
                    onCountChanged: Qt.callLater(reveal)

                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: candidateList.width
                        height: 28
                        radius: Math.min(4, theme.radius)
                        color: index === st.selectedCandidate ? Qt.rgba(Material.accentColor.r, Material.accentColor.g, Material.accentColor.b, 0.22) : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 12
                            Label { text: index + 1; opacity: 0.5; Layout.preferredWidth: 32 }
                            Label {
                                text: modelData.text
                                font.pixelSize: 15
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            Label {
                                font.family: "monospace"
                                opacity: 0.8
                                // The collocation term is a discount, so it reads as a subtraction.
                                text: modelData.collocationCost !== 0
                                      ? qsTr("%1 = %2 + %3 − %4").arg(modelData.cost).arg(modelData.wordCost).arg(modelData.connectionCost).arg(-modelData.collocationCost)
                                      : qsTr("%1 = %2 + %3").arg(modelData.cost).arg(modelData.wordCost).arg(modelData.connectionCost)
                            }
                        }
                        MouseArea { anchors.fill: parent; onClicked: backend.selectCandidate(index) }
                    }
                }

                Label {
                    anchors.centerIn: parent
                    visible: candidates.length === 0
                    text: st.reading ? qsTr("候補がありません") : qsTr("読みを入力すると、ここに変換候補とコストが並ぶ")
                    opacity: 0.5
                }
            }

            TabBar {
                objectName: "tabs"
                id: tabs
                Layout.fillWidth: true
                TabButton { text: qsTr("単語") }
                TabButton { text: qsTr("共起") }
                TabButton { text: qsTr("接続") }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: tabs.currentIndex
                WordPane { st: win.st }
                CollocationPane { st: win.st }
                ConnectionPane { st: win.st }
            }
        }

        // ── キー操作の一覧 ──────────────────────────────────────────────
        Rectangle {
            anchors.fill: parent
            visible: win.helpVisible
            color: "#cc000000"
            MouseArea { anchors.fill: parent; onClicked: win.helpVisible = false }

            Rectangle {
                anchors.centerIn: parent
                width: Math.min(parent.width - 64, 520)
                height: helpColumn.implicitHeight + 48
                color: "#1c1c21"
                radius: theme.radius

                GridLayout {
                    id: helpColumn
                    anchors.fill: parent
                    anchors.margins: 24
                    columns: 2
                    columnSpacing: 24
                    rowSpacing: 8
                    Repeater {
                        model: [
                            ["/  Ctrl+L", qsTr("読みの入力欄へ")],
                            ["Enter", qsTr("読みを変換し直す")],
                            ["J  K  ↓  ↑", qsTr("候補を選ぶ（接続ペインの対象）")],
                            ["Ctrl+1 2 3", qsTr("単語 / 共起 / 接続")],
                            ["?", qsTr("この一覧")],
                            ["Q  Ctrl+Q", qsTr("終了")]
                        ]
                        delegate: RowLayout {
                            required property var modelData
                            Layout.columnSpan: 2
                            Label { text: modelData[0]; font.family: "monospace"; color: Material.accentColor; Layout.preferredWidth: 140 }
                            Label { text: modelData[1] }
                        }
                    }
                    Label {
                        Layout.columnSpan: 2
                        Layout.topMargin: 8
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        opacity: 0.6
                        text: qsTr("編集はすぐにユーザー辞書（%1）へ保存され、入力中の vimeu にも反映される。").arg(st.userDirectory || "")
                    }
                }
            }
        }
    }
}
