// Avertissement modal HTTP externe. QtQuick 2.15, sans Controls ni effets GPU.
// Aucune persistance : consentement limite a une origine et a ce lancement.
import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin

FocusScope {
    id: warning
    visible: false
    enabled: visible
    focus: visible

    property string pendingUrl: ""
    property var _callback: null

    function confirm(url, callback) {
        if (visible) return false
        if (!url || !Jellyfin.isWanHttpUrl(url)) {
            if (callback) callback(false)
            return false
        }
        if (Jellyfin.hasWanHttpConsent(url)) {
            if (callback) callback(true)
            return true
        }
        pendingUrl = String(url)
        _callback = callback
        visible = true
        Qt.callLater(function() {
            if (warning.visible) cancelButton.forceActiveFocus()
        })
        return true
    }

    function finish(continueAnyway) {
        if (!visible) return
        var approved = continueAnyway === true
                && Jellyfin.grantWanHttpConsent(pendingUrl) === true
        var cb = _callback
        _callback = null
        pendingUrl = ""
        visible = false
        if (typeof cb === "function") cb(approved)
    }

    Keys.priority: Keys.BeforeItem
    // Ne fermer qu'au relâchement : empêche Back de traverser le dialogue
    // puis de fermer le volet parent dans le même appui télécommande.
    Keys.onPressed: {
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape)
            event.accepted = true
    }
    Keys.onReleased: {
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            event.accepted = true
            warning.finish(false)
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#DD000000"
        MouseArea { anchors.fill: parent; onClicked: warning.finish(false) }
    }

    Rectangle {
        id: dialogPanel
        anchors.centerIn: parent
        width: Math.min(parent.width - 70, 800)
        height: 360
        radius: 22
        color: "#141414"
        border.color: "#606060"
        border.width: 1

        Rectangle {
            x: 32; y: 32; width: 6; height: 54; radius: 3
            color: "#FFBE64"
        }

        Text {
            x: 55; y: 34
            width: parent.width - 92
            text: "Connexion non sécurisée"
            textFormat: Text.PlainText
            color: "#FFFFFF"
            font.pixelSize: 30
            font.bold: true
        }

        Text {
            x: 35; y: 105
            width: parent.width - 70
            text: "Ce serveur Jellyfin utilise HTTP sans chiffrement. La destination n’est pas vérifiée comme locale : vos identifiants, jetons et informations de lecture peuvent être interceptés ou modifiés.\n\nHTTPS est recommandé. Voulez-vous poursuivre malgré ces risques ?"
            textFormat: Text.PlainText
            color: "#D5D5D5"
            font.pixelSize: 19
            wrapMode: Text.WordWrap
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 30
            spacing: 22

            Rectangle {
                id: cancelButton
                width: 220; height: 58; radius: 16
                focus: true
                color: activeFocus ? "#FFFFFF" : "#272727"
                border.width: activeFocus ? 2 : 1
                border.color: activeFocus ? "#FFFFFF" : "#666666"
                scale: activeFocus ? 1.035 : 1.0
                Behavior on scale { NumberAnimation { duration: 110 } }
                KeyNavigation.right: continueButton
                Keys.onReturnPressed: warning.finish(false)
                Keys.onEnterPressed: warning.finish(false)
                Keys.onPressed: {
                    if (event.key === Qt.Key_Select) {
                        warning.finish(false); event.accepted = true
                    }
                }
                MouseArea { anchors.fill: parent; onClicked: warning.finish(false) }
                Text {
                    anchors.centerIn: parent
                    text: "Annuler"
                    textFormat: Text.PlainText
                    color: cancelButton.activeFocus ? "#000000" : "#FFFFFF"
                    font.pixelSize: 20
                    font.bold: cancelButton.activeFocus
                }
            }
            Rectangle {
                id: continueButton
                width: 220; height: 58; radius: 16
                color: activeFocus ? "#FFFFFF" : "#272727"
                border.width: activeFocus ? 2 : 1
                border.color: activeFocus ? "#FFFFFF" : "#666666"
                scale: activeFocus ? 1.035 : 1.0
                Behavior on scale { NumberAnimation { duration: 110 } }
                KeyNavigation.left: cancelButton
                Keys.onReturnPressed: warning.finish(true)
                Keys.onEnterPressed: warning.finish(true)
                Keys.onPressed: {
                    if (event.key === Qt.Key_Select) {
                        warning.finish(true); event.accepted = true
                    }
                }
                MouseArea { anchors.fill: parent; onClicked: warning.finish(true) }
                Text {
                    anchors.centerIn: parent
                    text: "Poursuivre"
                    textFormat: Text.PlainText
                    color: continueButton.activeFocus ? "#000000" : "#FFFFFF"
                    font.pixelSize: 20
                    font.bold: continueButton.activeFocus
                }
            }
        }
    }
}
