// qml/components/UpdateDialog.qml
// Popup de mise à jour ReDeFin avec changelog complet scrollable.
// QtQuick 2.15 uniquement.
// Aucun QtQuick Controls.

import QtQuick 2.15
import fbx.application 1.0

FocusScope {
    id: root

    visible: false
    enabled: visible
    focus: visible

    property string availableVersion: ""
    property string localVersion: ""
    property string channel: ""
    property string releaseNotes: ""

    // URI validée expérimentalement :
    // ouvre le Free Store.
    property string freeStoreUrl:
        "app:fr.freebox.freestore?package=com.lab.redefin"

    // 0 = Plus tard
    // 1 = Ouvrir le Free Store
    property int selectedAction: 1

    // Défilement par pression télécommande.
    property int scrollStep: 88

    // Style boutons calqué sur LoginPage V4.
    readonly property color uiSurfaceRaised: "#171717"
    readonly property color uiBorder: "#383838"
    readonly property color uiBorderStrong: "#5A5A5A"
    readonly property color uiFocus: "#FFFFFF"
    readonly property color uiText: "#FFFFFF"
    readonly property color uiTextSecondary: "#C8C8C8"
    readonly property real uiButtonFocusScale: 1.035
    readonly property int uiFocusLiftPx: 4

    signal dismissed()
    signal accepted()

    readonly property bool hasNotes:
        String(releaseNotes || "").trim().length > 0

    readonly property bool notesScrollable:
        hasNotes &&
        notesFlick.contentHeight > notesFlick.height + 1

    // Tant que la boîte est visible, elle reste l'autorité de focus.
    // Ceci empêche ShellPage ou une page chargée de récupérer le D-Pad/Back
    // pendant l'affichage de la mise à jour.
    onVisibleChanged: {
        if (visible) {
            Qt.callLater(function() {
                if (!root.visible)
                    return

                try {
                    root.forceActiveFocus(Qt.OtherFocusReason)
                } catch (e0) {}
            })
        }
    }

    onActiveFocusChanged: {
        if (visible && !activeFocus) {
            Qt.callLater(function() {
                if (!root.visible || root.activeFocus)
                    return

                try {
                    root.forceActiveFocus(Qt.OtherFocusReason)
                } catch (e0) {}
            })
        }
    }

    function open() {
        selectedAction = 1

        try {
            notesScrollAnimation.stop()
            notesFlick.contentY = 0
        } catch (e0) {}

        visible = true

        Qt.callLater(function() {
            try {
                root.forceActiveFocus(
                    Qt.OtherFocusReason
                )
            } catch (e1) {}
        })
    }

    function _dismiss() {
        visible = false
        dismissed()
    }

    function _openFreeStore() {
        var url = String(freeStoreUrl || "").trim()

        if (!url.length) {
            _dismiss()
            return
        }

        var opened = false

        // Délégation standard QML.
        try {
            opened = Qt.openUrlExternally(url) === true
        } catch (e0) {
            opened = false
        }

        // Fallback SDK Freebox.
        if (!opened) {
            try {
                App.urlOpen(url, "")
                opened = true
            } catch (e1) {
                opened = false
            }
        }

        visible = false
        accepted()
    }

    function _scrollNotes(delta) {
        if (!notesScrollable)
            return false

        var maxY = Math.max(
                    0,
                    notesFlick.contentHeight -
                    notesFlick.height
                )

        // Enchaîner les pressions à partir de la destination courante
        // évite les retours en arrière lors d'un scroll rapide.
        var baseY = notesScrollAnimation.running
                ? Number(notesScrollAnimation.to)
                : Number(notesFlick.contentY)

        var nextY = baseY + delta

        if (nextY < 0)
            nextY = 0
        else if (nextY > maxY)
            nextY = maxY

        if (Math.abs(nextY - baseY) < 0.5)
            return false

        notesScrollAnimation.stop()
        notesScrollAnimation.from = notesFlick.contentY
        notesScrollAnimation.to = nextY
        notesScrollAnimation.start()
        return true
    }

    NumberAnimation {
        id: notesScrollAnimation
        target: notesFlick
        property: "contentY"
        duration: 180
        easing.type: Easing.OutCubic
    }

    Rectangle {
        anchors.fill: parent
        color: "#99000000"
    }

    Rectangle {
        id: panel

        width: 820
        height: root.hasNotes ? 520 : 340

        anchors.centerIn: parent

        radius: 20
        color: "#101010"

        border.width: 2
        border.color: "#353535"

        Text {
            id: titleText

            anchors.top: parent.top
            anchors.topMargin: 28
            anchors.horizontalCenter:
                parent.horizontalCenter

            text: "Mise à jour disponible"

            color: "#FFFFFF"

            font.pixelSize: 30
            font.bold: true
        }

        Text {
            id: versionText

            anchors.top: titleText.bottom
            anchors.topMargin: 12
            anchors.horizontalCenter:
                parent.horizontalCenter

            text:
                root.availableVersion.length > 0
                ? "ReDeFin " + root.availableVersion
                : "Nouvelle version de ReDeFin"

            // availableVersion vient du manifest distant : jamais de RichText.
            textFormat: Text.PlainText

            color: "#F2F2F2"

            font.pixelSize: 24
            font.bold: true
        }

        Text {
            id: infoText

            anchors.top: versionText.bottom
            anchors.topMargin: 12
            anchors.horizontalCenter:
                parent.horizontalCenter

            width: panel.width - 90

            horizontalAlignment:
                Text.AlignHCenter

            wrapMode:
                Text.WordWrap

            text:
                "Une nouvelle version est disponible sur le Free Store."

            color: "#CCCCCC"

            font.pixelSize: 18
        }

        Rectangle {
            id: notesFrame

            visible: root.hasNotes

            anchors.top: infoText.bottom
            anchors.topMargin: 18
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 50
            anchors.rightMargin: 50
            height: 200

            radius: 12
            color: "#171717"

            border.width: 1
            border.color: "#303030"

            clip: true

            Flickable {
                id: notesFlick

                anchors.fill: parent
                anchors.leftMargin: 18
                anchors.rightMargin:
                    root.notesScrollable ? 30 : 18
                anchors.topMargin: 14
                anchors.bottomMargin: 14

                contentWidth: width
                contentHeight:
                    Math.max(
                        height,
                        notesText.paintedHeight
                    )

                clip: true

                interactive: true
                boundsBehavior:
                    Flickable.StopAtBounds

                flickableDirection:
                    Flickable.VerticalFlick

                Text {
                    id: notesText

                    x: 0
                    y: 0

                    width: notesFlick.width
                    height: paintedHeight

                    text:
                        root.releaseNotes

                    textFormat:
                        Text.PlainText

                    wrapMode:
                        Text.WordWrap

                    color: "#D0D0D0"

                    font.pixelSize: 17

                    horizontalAlignment:
                        Text.AlignLeft

                    verticalAlignment:
                        Text.AlignTop
                }
            }

            // Rail de l'ascenseur.
            Rectangle {
                id: scrollTrack

                visible: root.notesScrollable

                width: 5
                radius: 3

                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: parent.right

                anchors.topMargin: 14
                anchors.bottomMargin: 14
                anchors.rightMargin: 12

                color: "#292929"

                Rectangle {
                    id: scrollThumb

                    width: parent.width
                    radius: parent.radius

                    height:
                        Math.max(
                            24,
                            parent.height *
                            notesFlick.visibleArea.heightRatio
                        )

                    y:
                        Math.max(
                            0,
                            Math.min(
                                parent.height - height,
                                notesFlick.visibleArea.yPosition *
                                parent.height
                            )
                        )

                    color: "#B8B8B8"
                }
            }
        }

        Row {
            id: actions

            spacing: 16

            anchors.horizontalCenter:
                parent.horizontalCenter

            anchors.bottom:
                parent.bottom

            anchors.bottomMargin: 28

            // Bouton secondaire : même comportement que QuickConnect
            // sur LoginPage V4.
            Rectangle {
                id: laterButton

                width: 190
                height: 54
                radius: 18

                property bool selected:
                    root.selectedAction === 0

                color:
                    selected
                    ? root.uiFocus
                    : "transparent"

                border.width: 1

                border.color:
                    selected
                    ? root.uiFocus
                    : root.uiBorderStrong

                scale:
                    selected
                    ? root.uiButtonFocusScale
                    : 1.0

                transform: Translate {
                    y:
                        laterButton.selected
                        ? -root.uiFocusLiftPx
                        : 0

                    Behavior on y {
                        NumberAnimation {
                            duration: 115
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                Behavior on scale {
                    NumberAnimation {
                        duration: 115
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 90
                    }
                }

                Text {
                    anchors.centerIn: parent

                    text: "Plus tard"
                    textFormat: Text.PlainText

                    color:
                        laterButton.selected
                        ? "#000000"
                        : root.uiTextSecondary

                    font.pixelSize: 18
                    font.bold: laterButton.selected

                    Behavior on color {
                        ColorAnimation {
                            duration: 90
                        }
                    }
                }
            }

            // Bouton principal : même comportement que "Se connecter"
            // sur LoginPage V4.
            Rectangle {
                id: openStoreButton

                width: 285
                height: 54
                radius: 18

                property bool selected:
                    root.selectedAction === 1

                color:
                    selected
                    ? root.uiFocus
                    : root.uiSurfaceRaised

                border.width:
                    selected
                    ? 0
                    : 1

                border.color:
                    root.uiBorder

                scale:
                    selected
                    ? root.uiButtonFocusScale
                    : 1.0

                transform: Translate {
                    y:
                        openStoreButton.selected
                        ? -root.uiFocusLiftPx
                        : 0

                    Behavior on y {
                        NumberAnimation {
                            duration: 115
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                Behavior on scale {
                    NumberAnimation {
                        duration: 115
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 90
                    }
                }

                Text {
                    anchors.centerIn: parent

                    text: "Ouvrir le Free Store"
                    textFormat: Text.PlainText

                    color:
                        openStoreButton.selected
                        ? "#000000"
                        : root.uiText

                    font.pixelSize: 18
                    font.bold: openStoreButton.selected

                    Behavior on color {
                        ColorAnimation {
                            duration: 90
                        }
                    }
                }
            }
        }
    }

    Keys.priority:
        Keys.BeforeItem

    Keys.onShortcutOverride: {
        if (!visible)
            return

        if (event.key === Qt.Key_Back ||
                event.key === Qt.Key_Escape ||
                event.key === Qt.Key_Left ||
                event.key === Qt.Key_Right ||
                event.key === Qt.Key_Up ||
                event.key === Qt.Key_Down ||
                event.key === Qt.Key_Return ||
                event.key === Qt.Key_Enter ||
                event.key === Qt.Key_Select) {
            event.accepted = true
        }
    }

    Keys.onPressed: {
        if (!visible)
            return

        if (event.key === Qt.Key_Up) {
            root._scrollNotes(-root.scrollStep)
            event.accepted = true
            return
        }

        if (event.key === Qt.Key_Down) {
            root._scrollNotes(root.scrollStep)
            event.accepted = true
            return
        }

        if (event.key === Qt.Key_Left) {
            selectedAction = 0
            event.accepted = true
            return
        }

        if (event.key === Qt.Key_Right) {
            selectedAction = 1
            event.accepted = true
            return
        }

        if (event.key === Qt.Key_Return
                || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Select) {

            if (selectedAction === 0)
                _dismiss()
            else
                _openFreeStore()

            event.accepted = true
            return
        }

        if (event.key === Qt.Key_Back ||
                event.key === Qt.Key_Escape) {

            // Retour ignore cette mise à jour pour la session courante,
            // exactement comme le bouton "Plus tard".
            event.accepted = true
            _dismiss()
            return
        }

        // Empêche les touches de traverser vers la page sous-jacente.
        event.accepted = true
    }

    Keys.onReleased: {
        if (visible)
            event.accepted = true
    }
}
