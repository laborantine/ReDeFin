import QtQuick 2.15
import "../js/MediaCatalog.js" as MediaCatalog
import "." as Pages

FocusScope {
    id: root
    anchors.fill: parent
    focus: false

    property string serverUrl: ""
    property string accessToken: ""
    property string itemId: ""
    property bool controlsVisible: true
    property bool allowUi: true
    property bool buttonFocused: false
    property int safeBottomMargin: 40
    property int currentPlaybackMs: 0
    property int cardWidth: 260
    property int imageHeight: 146
    property int cardGap: 10
    property bool panelOpen: false

    property alias chapters: chapterCarousel.chapters
    property alias chaptersResolved: chapterCarousel.chaptersResolved
    property alias lastFocusedIndex: chapterCarousel.lastFocusedIndex
    readonly property bool hasContent: chapterCarousel.hasContent

    signal requestSeek(int startMs)
    signal requestFocusProgress()
    signal requestFocusControls()
    signal requestButtonFocus()
    signal userActivity()

    function _indexForPosition(ms) {
        return chapterCarousel.indexForPosition(ms, 250)
    }
    function seekRelativeChapter(step, playbackMs) {
        if (!hasContent || !allowUi) return false
        var direction = Number(step) < 0 ? -1 : 1
        var target = _indexForPosition(playbackMs) + direction
        if (target < 0 || target >= chapters.length) return false
        lastFocusedIndex = target
        requestSeek(MediaCatalog.chapterStartMs(chapters[target]))
        userActivity()
        return true
    }
    function openPanel(playbackMs) {
        if (!allowUi || !hasContent) return false
        currentPlaybackMs = Math.max(0, Math.floor(Number(playbackMs || 0)))
        lastFocusedIndex = _indexForPosition(currentPlaybackMs)
        panelOpen = true
        userActivity()
        Qt.callLater(function(){
            if (root.panelOpen) chapterCarousel.focusIndex(root.lastFocusedIndex)
        })
        return true
    }
    function closeToButton() {
        if (!panelOpen) return
        panelOpen = false
        userActivity()
        requestButtonFocus()
    }
    function activateFocused() {
        if (!panelOpen || !hasContent) return false
        return chapterCarousel.activateCurrent()
    }
    function _activateChapter(chapter) {
        if (!chapter) return false
        requestSeek(MediaCatalog.chapterStartMs(chapter))
        panelOpen = false
        requestButtonFocus()
        userActivity()
        return true
    }

    onServerUrlChanged: panelOpen = false
    onAccessTokenChanged: panelOpen = false
    onItemIdChanged: panelOpen = false
    onHasContentChanged: {
        if (!hasContent) {
            panelOpen = false
            if (buttonFocused) requestFocusProgress()
        }
    }
    onAllowUiChanged: if (!allowUi) panelOpen = false

    Rectangle {
        width: 56
        height: 56
        radius: 28
        anchors.left: parent.left
        // Groupe gauche : Zoom x=80, Vitesse x=150, puis Chapitres x=220.
        anchors.leftMargin: 220
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.safeBottomMargin
        // Quand le panneau est ouvert, le bouton reste à sa position logique
        // mais passe derrière la bande noire opaque. Aucun saut de géométrie.
        z: root.panelOpen ? 10 : 40
        enabled: !root.panelOpen
        visible: root.allowUi && root.controlsVisible && root.hasContent
        opacity: visible ? 0.98 : 0.0
        color: Qt.rgba(0, 0, 0, 0.45)
        border.width: root.buttonFocused ? 2 : 1
        border.color: root.buttonFocused ? Qt.rgba(1,1,1,0.75) : Qt.rgba(1,1,1,0.25)
        Behavior on opacity { OpacityAnimator { duration: 160 } }

        Rectangle {
            anchors.fill: parent
            radius: 28
            color: Qt.rgba(1,1,1,0.15)
            opacity: root.buttonFocused ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 110 } }
        }

        Item {
            anchors.centerIn: parent
            width: 30
            height: 28
            Rectangle {
                x: 2; y: 2; width: 26; height: 7
                color: "#F2F4F8"; rotation: -6; transformOrigin: Item.Center; clip: true
                Repeater {
                    model: 4
                    Rectangle { width: 5; height: 14; x: index * 8 - 2; y: -3; color: "#171A21"; rotation: -28 }
                }
            }
            Rectangle {
                x: 3; y: 11; width: 24; height: 15
                color: "transparent"; border.width: 2; border.color: "#F2F4F8"
                Rectangle { x: 4; y: 5; width: 16; height: 2; color: "#F2F4F8"; opacity: 0.8 }
                Rectangle { x: 4; y: 10; width: 11; height: 2; color: "#F2F4F8"; opacity: 0.8 }
            }
        }
        MouseArea {
            anchors.fill: parent
            onClicked: {
                root.requestButtonFocus()
                root.openPanel(root.currentPlaybackMs)
            }
        }
    }

    Rectangle {
        id: panel
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 0
        height: root.imageHeight + 104
        radius: 14
        z: 20
        visible: root.panelOpen && root.hasContent && root.allowUi
        opacity: root.panelOpen ? 1.0 : 0.0
        scale: root.panelOpen ? 1.0 : 0.98
        color: "#07090D"
        border.color: Qt.rgba(1,1,1,0.30)
        border.width: 1
        clip: true
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        Text {
            id: panelTitle
            anchors.left: parent.left
            anchors.leftMargin: 80
            anchors.top: parent.top
            anchors.topMargin: 8
            text: "Chapitres"
            color: "#FFFFFF"
            font.pixelSize: 20
            font.bold: true
        }

        Item {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.top: panelTitle.bottom
            anchors.topMargin: 8
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            clip: true

            Pages.ChaptersCarousel {
                id: chapterCarousel
                anchors.fill: parent
                serverUrl: root.serverUrl
                accessToken: root.accessToken
                itemId: root.itemId
                fetchEnabled: true
                displayEnabled: root.panelOpen && root.allowUi
                sectionTitleVisible: false
                fillAvailableHeight: true
                compactPlayerStyle: true
                activateOnClick: true
                consumeBackKey: true
                sectionLeftMargin: 0
                cardWidth: root.cardWidth
                imageHeight: root.imageHeight
                cardGap: root.cardGap

                onChapterActivated: function(index, chapter) { root._activateChapter(chapter) }
                onUserActivity: root.userActivity()
                onRequestFocusAbove: root.closeToButton()
                onRequestFocusBelow: root.closeToButton()
                onRequestBack: root.closeToButton()
            }
        }
    }
}
