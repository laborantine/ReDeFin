// qml/components/UnsupportedDialog.qml
// Boîte de dialogue modale — "fonctionnalité non supportée"

import QtQuick 2.15

FocusScope {
    id: dialog
    anchors.fill: parent
    z: 10000

    /* -------- API -------- */
    property alias text:    msgText.text
    property string title:  "Information"
    property real overlayOpacity: 0.55
    signal requestClose()
    signal closed()

    /* -------- État -------- */
    property bool _open: false

    visible: _open
    enabled: _open
    focus:   _open

    /* Intercepter les touches AVANT tout */
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: {
        if (!_open) return;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
            dialog.requestClose(); dialog.close(); event.accepted = true;
        } else if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            dialog.requestClose(); dialog.close(); event.accepted = true;
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right ||
                   event.key === Qt.Key_Up   || event.key === Qt.Key_Down) {
            // Empêche la vue du dessous de bouger
            event.accepted = true;
        }
    }

    /* Watchdog focus: si on perd le focus alors qu'on est ouvert → reprendre */
    onActiveFocusChanged: {
        if (_open && !activeFocus) Qt.callLater(function(){ dialog.forceActiveFocus(); });
    }
    onVisibleChanged: {
        if (_open && visible) {
            dialog.forceActiveFocus();
            focusKeeper.restart();
        } else {
            focusKeeper.stop();
        }
    }

    Timer {
        id: focusKeeper
        interval: 250
        repeat: true
        running: false
        onTriggered: {
            if (dialog._open && (!dialog.activeFocus)) dialog.forceActiveFocus();
        }
    }

    function open(message, secondary) {
        if (message   !== undefined && message   !== null) msgText.text = String(message);
        if (secondary !== undefined && secondary !== null) subText.text = String(secondary);
        _open = true;

        // Forcer la prise de focus immédiatement, puis sur le bouton
        dialog.forceActiveFocus();
        Qt.callLater(function() {
            if (okBtn) okBtn.forceActiveFocus();
        });
        focusKeeper.start();
    }

    function close() {
        if (!_open) return;
        _open = false;
        focusKeeper.stop();
        dialog.closed();
    }

    /* -------- Overlay modal qui bloque tout clic derrière -------- */
    Rectangle {
        anchors.fill: parent
        color: "#000"
        opacity: overlayOpacity
        visible: dialog.visible

        // Bloquer la souris/tap derrière
        MouseArea {
            anchors.fill: parent
            enabled: dialog.visible
            preventStealing: true
            propagateComposedEvents: false
            onClicked: { dialog.requestClose(); dialog.close(); }
        }
    }

    /* -------- Carte centrale -------- */
    Rectangle {
        id: card
        width: Math.min(parent.width * 0.60, 640)
        height: implicitHeight
        implicitHeight: contentCol.implicitHeight + 32
        radius: 14
        color: "#111424"
        border.color: "#ffffff"
        border.width: 2
        anchors.centerIn: parent

        Column {
            id: contentCol
            width: parent.width
            spacing: 14
            anchors.fill: parent
            anchors.margins: 18

            Text {
                id: titleText
                text: dialog.title
                textFormat: Text.PlainText
                color: "#ffffff"
                font.pixelSize: 22
                font.bold: true
            }

            Text {
                id: msgText
                text: "Fonctionnalité non supportée"
                textFormat: Text.PlainText
                color: "#e9ecff"
                font.pixelSize: 18
                wrapMode: Text.WordWrap
                maximumLineCount: 5
                elide: Text.ElideRight
            }

            Text {
                id: subText
                text: ""
                textFormat: Text.PlainText
                color: "#c6cbee"
                font.pixelSize: 14
                wrapMode: Text.WordWrap
                visible: text.length > 0
            }

            /* ---- Bouton OK ---- */
            FocusScope {
                id: okBtn
                objectName: "okButton"
                width: 120
                height: 42
                anchors.horizontalCenter: parent.horizontalCenter
                focus: true

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                        dialog.requestClose(); dialog.close(); event.accepted = true;
                    } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                        dialog.requestClose(); dialog.close(); event.accepted = true;
                    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right ||
                               event.key === Qt.Key_Up   || event.key === Qt.Key_Down) {
                        event.accepted = true;
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: 10
                    color: okBtn.activeFocus ? "#2f3660" : "#242a4a"
                    border.color: "#FFFFFF"
                    border.width: okBtn.activeFocus ? 2 : 1
                    Behavior on color { NumberAnimation { duration: 100 } }
                    Behavior on border.width { NumberAnimation { duration: 100 } }

                    Text {
                        anchors.centerIn: parent
                        text: "OK"
                        textFormat: Text.PlainText
                        color: "#ffffff"
                        font.pixelSize: 18
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: dialog.visible
                        preventStealing: true
                        propagateComposedEvents: false
                        hoverEnabled: true
                        onEntered: okBtn.forceActiveFocus()
                        onClicked: { dialog.requestClose(); dialog.close(); }
                    }
                }
            }
        }
    }
}
