import QtQuick
import QtQuick.Controls.Material

// A compact number field for list rows. Material's TextField is about 56 px
// tall and spills over the rows, so this draws a plain outlined input.
Rectangle {
    id: field
    signal accepted(int value)
    property int maximum: 32767

    implicitWidth: 80
    implicitHeight: 30
    radius: Math.min(4, theme.radius)
    color: "transparent"
    border.color: input.activeFocus ? Material.accentColor : Qt.rgba(1, 1, 1, 0.25)

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignRight
        color: Material.foreground
        selectionColor: Material.accentColor
        font.family: "monospace"
        selectByMouse: true
        validator: IntValidator { bottom: 0; top: field.maximum }
        onAccepted: {
            field.accepted(parseInt(text))
            text = ""
        }
    }
    Text {
        anchors.fill: input
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignRight
        text: qsTr("値")
        color: Material.hintTextColor
        visible: input.text.length === 0 && !input.activeFocus
    }
}
