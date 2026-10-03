// qml/components/RemoteMessageOverlay.qml
// Notifications distantes Jellyfin au style "push / chat".
// QtQuick 2.15 uniquement, aucun QtQuick Controls, aucun shader/effect lourd.
// Pensé pour Révolution : maximum 3 cartes, animations courtes, Text.PlainText.
import QtQuick 2.15

Item {
    id: root
    anchors.fill: parent
    visible: messageModel.count > 0
    enabled: false

    property int maxVisibleMessages: 3
    property int cardWidth: Math.min(520, Math.max(420, Math.round(width * 0.27)))
    property int rightMargin: 42
    property int topMargin: 92
    property int spacing: 14
    property int _nextMessageId: 1

    function _s(value) {
        return (value === undefined || value === null) ? "" : String(value)
    }

    function _clampTimeout(value) {
        var n = Number(value)
        if (!isFinite(n) || isNaN(n) || n <= 0)
            n = 5000
        return Math.max(2500, Math.min(15000, Math.floor(n)))
    }

    function showMessage(header, text, timeoutMs) {
        var body = _s(text).trim()
        if (!body.length)
            return false

        var title = _s(header).trim()
        if (!title.length)
            title = "Message Jellyfin"

        // Défense UI : ne jamais laisser une commande distante construire
        // une très grande arborescence texte sur une Révolution.
        if (title.length > 90)
            title = title.substring(0, 87) + "..."
        if (body.length > 600)
            body = body.substring(0, 597) + "..."

        var id = _nextMessageId++
        if (_nextMessageId > 2000000000)
            _nextMessageId = 1

        while (messageModel.count >= Math.max(1, maxVisibleMessages))
            messageModel.remove(0)

        messageModel.append({
            noticeId: id,
            noticeHeader: title,
            noticeText: body,
            noticeTimeout: _clampTimeout(timeoutMs)
        })
        return true
    }

    function dismissMessage(noticeId) {
        for (var i = 0; i < messageModel.count; ++i) {
            if (Number(messageModel.get(i).noticeId) === Number(noticeId)) {
                messageModel.remove(i)
                return true
            }
        }
        return false
    }

    function clearAll() {
        messageModel.clear()
    }

    ListModel {
        id: messageModel
    }

    Column {
        id: messageColumn
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: root.topMargin
        anchors.rightMargin: root.rightMargin
        spacing: root.spacing
        width: root.cardWidth

        Repeater {
            model: messageModel

            delegate: Item {
                id: slot
                width: messageColumn.width
                height: Math.max(104, card.height) + 2

                property bool closing: false
                property int myNoticeId: Number(noticeId)

                Rectangle {
                    id: card
                    width: slot.width - 18
                    height: Math.max(104,
                                     messageBody.y
                                     + messageBody.implicitHeight
                                     + 22)
                    x: slot.width + 56
                    opacity: 0.0
                    radius: 22
                    color: "#EE111722"
                    border.width: 1
                    border.color: "#35FFFFFF"
                    antialiasing: true

                    // Petite "queue" discrète côté droit pour l'aspect chat.
                    Rectangle {
                        width: 18
                        height: 18
                        anchors.right: parent.right
                        anchors.rightMargin: -7
                        anchors.verticalCenter: parent.verticalCenter
                        rotation: 45
                        radius: 3
                        color: parent.color
                        border.width: 0
                        antialiasing: true
                    }

                    // Accent vertical ReDeFin/Jellyfin, sans shader.
                    Rectangle {
                        width: 4
                        radius: 2
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.top: parent.top
                        anchors.topMargin: 16
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 16
                        color: "#6E7BF4"
                        opacity: 0.95
                    }

                    Rectangle {
                        id: avatar
                        width: 44
                        height: 44
                        radius: 22
                        anchors.left: parent.left
                        anchors.leftMargin: 26
                        anchors.top: parent.top
                        anchors.topMargin: 18
                        color: "#252C48"
                        border.width: 1
                        border.color: "#55798AFF"

                        Text {
                            anchors.centerIn: parent
                            text: "J"
                            color: "#FFFFFF"
                            font.pixelSize: 22
                            font.bold: true
                            textFormat: Text.PlainText
                        }
                    }

                    Text {
                        id: messageHeader
                        anchors.left: avatar.right
                        anchors.leftMargin: 14
                        anchors.right: parent.right
                        anchors.rightMargin: 22
                        anchors.top: parent.top
                        anchors.topMargin: 17
                        height: 28
                        text: String(noticeHeader || "Message Jellyfin")
                        color: "#FFFFFF"
                        font.pixelSize: 20
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                        textFormat: Text.PlainText
                    }

                    Text {
                        id: sourceLabel
                        anchors.left: messageHeader.left
                        anchors.right: messageHeader.right
                        anchors.top: messageHeader.bottom
                        anchors.topMargin: -1
                        height: 18
                        text: "Jellyfin • message distant"
                        color: "#9AA3BD"
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                        textFormat: Text.PlainText
                    }

                    Text {
                        id: messageBody
                        anchors.left: avatar.left
                        anchors.right: parent.right
                        anchors.rightMargin: 22
                        anchors.top: avatar.bottom
                        anchors.topMargin: 12
                        text: String(noticeText || "")
                        color: "#E7ECFF"
                        font.pixelSize: 19
                        font.weight: Font.Normal
                        lineHeight: 1.12
                        lineHeightMode: Text.ProportionalHeight
                        wrapMode: Text.Wrap
                        maximumLineCount: 5
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                }

                function beginClose() {
                    if (closing)
                        return
                    closing = true
                    lifeTimer.stop()
                    exitAnimation.start()
                }

                Timer {
                    id: lifeTimer
                    interval: Math.max(2500, Number(noticeTimeout || 5000))
                    repeat: false
                    onTriggered: slot.beginClose()
                }

                ParallelAnimation {
                    id: enterAnimation

                    NumberAnimation {
                        target: card
                        property: "x"
                        from: slot.width + 56
                        to: 0
                        duration: 230
                        easing.type: Easing.OutCubic
                    }

                    NumberAnimation {
                        target: card
                        property: "opacity"
                        from: 0.0
                        to: 1.0
                        duration: 170
                        easing.type: Easing.OutQuad
                    }

                    onStopped: {
                        if (!slot.closing)
                            lifeTimer.start()
                    }
                }

                SequentialAnimation {
                    id: exitAnimation

                    ParallelAnimation {
                        NumberAnimation {
                            target: card
                            property: "x"
                            to: slot.width + 56
                            duration: 190
                            easing.type: Easing.InCubic
                        }

                        NumberAnimation {
                            target: card
                            property: "opacity"
                            to: 0.0
                            duration: 145
                            easing.type: Easing.InQuad
                        }
                    }

                    ScriptAction {
                        script: root.dismissMessage(slot.myNoticeId)
                    }
                }

                Component.onCompleted: enterAnimation.start()
            }
        }
    }
}
