import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SeasonUtils.js" as SeasonUtils

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

    // Profil volontairement plus léger que les pages détail : ce composant
    // tourne pendant la lecture vidéo sur la Freebox Révolution.
    readonly property real imageOversample: 1.20
    readonly property int imageQuality: 82
    readonly property int requestImageWidth: Math.max(1, Math.round(cardWidth * imageOversample))
    readonly property int requestImageHeight: Math.max(1, Math.round(imageHeight * imageOversample))
    readonly property real hqImageOversample: 1.40
    readonly property int hqImageQuality: 88
    readonly property int requestHqImageWidth: Math.max(1, Math.round(cardWidth * hqImageOversample))
    readonly property int requestHqImageHeight: Math.max(1, Math.round(imageHeight * hqImageOversample))
    property int hqTargetIndex: -1
    property int _hqPendingIndex: -1
    property int lastFocusedIndex: 0
    property bool panelOpen: false
    property var chapters: []
    property int _requestSeq: 0
    property bool chaptersResolved: false
    readonly property bool hasContent: !!(chapters && chapters.length > 0)
    readonly property bool listMoving: !!(chapterList && (chapterList.moving || chapterList.dragging || chapterList.flicking))

    readonly property real focusScalePeak: 1.035
    readonly property real focusScaleRest: 1.025
    readonly property real frameWidth: 2.0
    readonly property int edgeNudgePx: Math.max(0, Math.ceil(cardWidth * (focusScalePeak - 1) * 0.55))
    readonly property int edgePad: Math.max(18, edgeNudgePx + 10)
    readonly property int focusSafetyPadY: 6

    signal requestSeek(int startMs)
    signal requestFocusProgress()
    signal requestFocusControls()
    signal requestButtonFocus()
    signal userActivity()
    function _cancelHq(){
        hqPromotionTimer.stop()
        _hqPendingIndex = -1
        hqTargetIndex = -1
    }
    function _scheduleHq(idx){
        hqPromotionTimer.stop()
        hqTargetIndex = -1
        idx = Number(idx) | 0
        if (!panelOpen || !allowUi || listMoving || !chapterList || !chapterList.activeFocus
                || idx < 0 || idx >= chapterList.count) {
            _hqPendingIndex = -1
            return
        }
        _hqPendingIndex = idx
        hqPromotionTimer.restart()
    }
    function _scheduleFetch(){
        _requestSeq++
        chaptersResolved = false
        chapters = []
        panelOpen = false
        focusRetry.stop()
        if (!serverUrl || !accessToken || !itemId) { fetchTimer.stop(); return }
        fetchTimer.restart()
    }
    function _fetch(){
        if (!serverUrl || !accessToken || !itemId) return
        var seq = _requestSeq, expectedServer = serverUrl, expectedToken = accessToken, expectedId = itemId
        Jellyfin.fetchItemChapters(expectedServer, expectedToken, expectedId,
            function(arr){
                if (seq !== _requestSeq || expectedServer !== serverUrl || expectedToken !== accessToken || expectedId !== itemId) return
                chapters = arr || []
                chaptersResolved = true
                if (lastFocusedIndex >= chapters.length) lastFocusedIndex = Math.max(0, chapters.length - 1)
                chapterList.currentIndex = chapters.length ? lastFocusedIndex : -1
            },
            function(){
                if (seq !== _requestSeq || expectedServer !== serverUrl || expectedToken !== accessToken || expectedId !== itemId) return
                chapters = []
                chaptersResolved = true
                chapterList.currentIndex = -1
                panelOpen = false
            }
        )
    }
    function _indexForPosition(ms){
        return SeasonUtils.chapterIndexForPosition(chapters, ms, 250)
    }
    function _itemAt(idx){
        if (!chapterList || idx < 0 || idx >= chapterList.count) return null
        try { return chapterList.itemAtIndex(idx) } catch(e) { return null }
    }
    function seekRelativeChapter(step, playbackMs){
        if (!hasContent || !allowUi) return false
        var dir = Number(step) < 0 ? -1 : 1
        var idx = _indexForPosition(playbackMs)
        var target = idx + dir
        if (target < 0 || target >= chapters.length) return false
        lastFocusedIndex = target
        requestSeek(SeasonUtils.chapterStartMs(chapters[target]))
        userActivity()
        return true
    }
    function _focusIndexSoon(idx){
        focusRetry.stop(); focusRetry.targetIndex = idx; focusRetry.tries = 0; focusRetry.interval = 0; focusRetry.restart()
    }
    function _focusIndex(idx){
        if (!hasContent) return false
        idx = Math.max(0, Math.min(chapters.length - 1, idx | 0))
        lastFocusedIndex = idx
        chapterList.currentIndex = idx
        chapterList.forceActiveFocus()
        _focusIndexSoon(idx)
        return true
    }
    function openPanel(playbackMs){
        if (!allowUi || !hasContent) return false
        currentPlaybackMs = Math.max(0, Math.floor(Number(playbackMs || 0)))
        lastFocusedIndex = _indexForPosition(currentPlaybackMs)
        panelOpen = true
        userActivity()
        Qt.callLater(function(){ if (root.panelOpen) root._focusIndex(root.lastFocusedIndex) })
        return true
    }
    function closeToButton(){
        if (!panelOpen) return
        panelOpen = false
        userActivity()
        requestButtonFocus()
    }
    function activateFocused(){
        if (!panelOpen || !hasContent) return false
        var idx = Math.max(0, Math.min(chapters.length - 1, chapterList.currentIndex | 0))
        var ch = chapters[idx]
        requestSeek(SeasonUtils.chapterStartMs(ch))
        panelOpen = false
        requestButtonFocus()
        return true
    }

    onServerUrlChanged: _scheduleFetch()
    onAccessTokenChanged: _scheduleFetch()
    onItemIdChanged: _scheduleFetch()
    onHasContentChanged: if (!hasContent && buttonFocused) requestFocusProgress()
    onAllowUiChanged: if (!allowUi) { panelOpen = false; _cancelHq() }
    onPanelOpenChanged: {
        if (!panelOpen) _cancelHq()
        else if (chapterList && chapterList.currentIndex >= 0)
            _scheduleHq(chapterList.currentIndex)
    }
    onListMovingChanged: {
        if (listMoving) _cancelHq()
        else if (panelOpen && chapterList && chapterList.activeFocus && chapterList.currentIndex >= 0)
            _scheduleHq(chapterList.currentIndex)
    }
    Component.onCompleted: _scheduleFetch()
    Component.onDestruction: { _requestSeq++; focusRetry.stop(); fetchTimer.stop(); _cancelHq() }

    Timer { id: fetchTimer; interval: 150; repeat: false; onTriggered: root._fetch() }
    Timer {
        id: hqPromotionTimer
        interval: 300
        repeat: false
        onTriggered: {
            var idx = chapterList ? (chapterList.currentIndex | 0) : -1
            root.hqTargetIndex = (root.panelOpen
                                  && root.allowUi
                                  && !root.listMoving
                                  && chapterList && chapterList.activeFocus
                                  && idx >= 0
                                  && idx === root._hqPendingIndex)
                                 ? idx : -1
        }
    }
    Timer {
        id: focusRetry
        repeat: false
        interval: 0
        property int targetIndex: -1
        property int tries: 0
        onTriggered: {
            if (!root.panelOpen || !root.hasContent || targetIndex < 0) return
            var obj = root._itemAt(targetIndex)
            if (obj && obj.forceActiveFocus) { obj.forceActiveFocus(); return }
            tries++
            if (tries < 10) { interval = 24; restart() }
        }
    }

    Rectangle {
        id: chapterButton
        width: 56
        height: 56
        radius: 28
        anchors.left: parent.left
        // Groupe gauche : Zoom x=80, Vitesse x=150, puis Chapitres x=220.
        // Le bouton reste ainsi le voisin immédiat des transports centraux.
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

        Rectangle { anchors.fill: parent; radius: 28; color: Qt.rgba(1,1,1,0.15); opacity: root.buttonFocused ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 110 } } }

        Item {
            anchors.centerIn: parent
            width: 30
            height: 28
            Rectangle {
                id: smallClapTop
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
        // Tiroir Chapitres réellement collé au bord inférieur. Il recouvre la
        // ProgressBar et la rangée de commandes sans déplacer leur géométrie.
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 0
        // Hauteur volontairement compacte : titre + vignette 16:9 + libellés.
        // La bande noire ne monte plus jusqu'à la ProgressBar.
        height: root.imageHeight + 104
        radius: 14
        z: 20
        visible: root.panelOpen && root.hasContent && root.allowUi
        opacity: root.panelOpen ? 1.0 : 0.0
        scale: root.panelOpen ? 1.0 : 0.98
        // Fond totalement opaque. La vidéo et les éléments placés derrière le
        // panneau ne doivent jamais transparaître dans les vignettes.
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

        // Viewport interne : le carrousel ne peut jamais déborder du cadre noir,
        // même lorsqu'une carte est légèrement agrandie au focus.
        Item {
            id: carouselViewport
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.top: panelTitle.bottom
            anchors.topMargin: 8
            anchors.bottom: parent.bottom
            // Plus aucune réserve pour la ProgressBar/PlayerControls : le
            // carrousel utilise toute la bande basse. Les commandes restent à
            // leur position habituelle mais sont recouvertes par ce panneau.
            anchors.bottomMargin: 6
            clip: true

            ListView {
                id: chapterList
                anchors.fill: parent
                orientation: ListView.Horizontal
            spacing: root.cardGap
            clip: true
            model: root.chapters
            currentIndex: -1
            enabled: root.panelOpen

            snapMode: ListView.NoSnap
            highlightFollowsCurrentItem: true
            highlightRangeMode: ListView.StrictlyEnforceRange
            preferredHighlightBegin: root.edgePad
            preferredHighlightEnd: Math.max(0, width - root.cardWidth - root.edgePad)
            highlightMoveDuration: root.panelOpen ? 170 : 0
            highlightMoveVelocity: -1
            highlight: Item { width: root.cardWidth; height: chapterList.height; visible: false }
            interactive: root.panelOpen && contentWidth > width + 2
            boundsBehavior: Flickable.StopAtBounds
            flickDeceleration: 5000
            maximumFlickVelocity: 3200
            reuseItems: true
            cacheBuffer: Math.max(180, Math.min(620, Math.round(root.cardWidth * 1.5)))
            header: Item { width: root.edgePad; height: 1 }
            footer: Item { width: root.edgePad; height: 1 }

            delegate: FocusScope {
                id: chapterCard
                width: root.cardWidth
                height: chapterList.height
                focus: ListView.isCurrentItem
                z: activeFocus ? 1000 : 0
                property bool imageFailed: false
                readonly property bool selected: activeFocus
                readonly property bool firstCard: index === 0
                readonly property bool lastCard: root.chapters && index === root.chapters.length - 1

                onActiveFocusChanged: {
                    if (activeFocus) {
                        root.lastFocusedIndex = index
                        chapterList.currentIndex = index
                        root._scheduleHq(index)
                    } else if (root.hqTargetIndex === index || root._hqPendingIndex === index) {
                        root._cancelHq()
                    }
                }

                Item {
                    id: cardVisual
                    x: chapterCard.selected ? (chapterCard.firstCard ? root.edgeNudgePx : (chapterCard.lastCard ? -root.edgeNudgePx : 0)) : 0
                    y: root.focusSafetyPadY
                    width: root.cardWidth
                    height: root.imageHeight + 50
                    transformOrigin: Item.Center
                    scale: 1.0
                    Behavior on x { enabled: !root.listMoving; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    SequentialAnimation {
                        id: softScaleIn
                        PropertyAnimation { target: cardVisual; property: "scale"; to: root.focusScalePeak; duration: 130; easing.type: Easing.OutCubic }
                        PropertyAnimation { target: cardVisual; property: "scale"; to: root.focusScaleRest; duration: 90; easing.type: Easing.OutCubic }
                    }
                    NumberAnimation {
                        id: softScaleOut
                        target: cardVisual; property: "scale"; to: 1.0; duration: 140; easing.type: Easing.OutCubic
                    }
                    onVisibleChanged: if (visible) scale = chapterCard.selected ? root.focusScaleRest : 1.0
                    Connections {
                        target: chapterCard
                        function onSelectedChanged(){
                            if (root.listMoving) { softScaleIn.stop(); softScaleOut.stop(); cardVisual.scale = chapterCard.selected ? root.focusScaleRest : 1.0; return }
                            if (chapterCard.selected) { softScaleOut.stop(); softScaleIn.start() }
                            else { softScaleIn.stop(); softScaleOut.start() }
                        }
                    }
                    Connections {
                        target: root
                        function onListMovingChanged(){ if (root.listMoving) { softScaleIn.stop(); softScaleOut.stop(); cardVisual.scale = chapterCard.selected ? root.focusScaleRest : 1.0 } }
                    }

                    Rectangle {
                        id: imageFrame
                        width: root.cardWidth
                        height: root.imageHeight
                        color: "#11141C"
                        border.width: 0
                        border.color: "transparent"
                        opacity: 1.0

                        Item {
                            anchors.fill: parent
                            anchors.margins: root.frameWidth
                            clip: true

                            Item {
                                anchors.fill: parent
                                visible: !chapterImage.source || chapterImage.status !== Image.Ready || chapterCard.imageFailed
                                Rectangle { anchors.fill: parent; color: "#10131A" }
                                Rectangle {
                                    id: clapTop
                                    x: Math.round(parent.width * 0.18)
                                    y: Math.round(parent.height * 0.22)
                                    width: Math.round(parent.width * 0.64)
                                    height: Math.round(parent.height * 0.18)
                                    color: "#E9EDF5"
                                    rotation: -5
                                    transformOrigin: Item.Center
                                    clip: true
                                    Repeater {
                                        model: 6
                                        Rectangle {
                                            width: Math.round(clapTop.width / 8)
                                            height: clapTop.height * 1.8
                                            x: index * Math.round(clapTop.width / 5) - 8
                                            y: -Math.round(clapTop.height * 0.4)
                                            color: "#151922"
                                            rotation: -28
                                        }
                                    }
                                }
                                Rectangle {
                                    x: Math.round(parent.width * 0.20)
                                    y: Math.round(parent.height * 0.43)
                                    width: Math.round(parent.width * 0.60)
                                    height: Math.round(parent.height * 0.37)
                                    color: "#171B24"
                                    border.width: 2
                                    border.color: "#D9DFEA"
                                    Rectangle { x: 14; y: 16; width: parent.width - 28; height: 2; color: "#7A8392" }
                                    Rectangle { x: 14; y: 31; width: parent.width - 28; height: 2; color: "#7A8392" }
                                    Rectangle { x: 14; y: 46; width: Math.round((parent.width - 28) * 0.62); height: 2; color: "#7A8392" }
                                }
                            }

                            Image {
                                id: chapterImage
                                anchors.fill: parent
                                source: SeasonUtils.chapterImageUrl(root.serverUrl, root.itemId, root.chapters, index, root.requestImageWidth, root.requestImageHeight, root.imageQuality)
                                asynchronous: true
                                cache: true
                                mipmap: false
                                smooth: !root.listMoving
                                fillMode: Image.PreserveAspectCrop
                                visible: status === Image.Ready && !chapterCard.imageFailed
                                onSourceChanged: chapterCard.imageFailed = false
                                onStatusChanged: {
                                    if (status === Image.Error) chapterCard.imageFailed = true
                                    else if (status === Image.Ready && chapterCard.selected)
                                        root._scheduleHq(index)
                                }
                            }

                            Image {
                                id: chapterImageHq
                                anchors.fill: parent
                                source: (chapterCard.selected
                                         && root.panelOpen
                                         && !root.listMoving
                                         && chapterImage.status === Image.Ready
                                         && root.hqTargetIndex === index)
                                        ? SeasonUtils.chapterImageUrl(root.serverUrl, root.itemId, root.chapters, index, root.requestHqImageWidth, root.requestHqImageHeight, root.hqImageQuality) : ""
                                asynchronous: true
                                cache: false
                                mipmap: false
                                smooth: !root.listMoving
                                fillMode: Image.PreserveAspectCrop
                                visible: source !== "" && status === Image.Ready && !chapterCard.imageFailed
                                opacity: visible ? 1.0 : 0.0
                                Behavior on opacity {
                                    enabled: !root.listMoving
                                    NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                                }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: "transparent"
                            border.width: root.frameWidth
                            border.color: "#FFFFFF"
                            opacity: chapterCard.selected ? 1.0 : 0.0
                            Behavior on opacity { enabled: !root.listMoving; NumberAnimation { duration: 125; easing.type: Easing.OutCubic } }
                        }
                    }

                    Text {
                        id: chapterName
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: imageFrame.bottom
                        anchors.topMargin: 7
                        text: SeasonUtils.chapterTitle(modelData)
                        color: "#FFFFFF"
                        font.pixelSize: 17
                        font.bold: chapterCard.selected
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                        height: text.length > 0 ? 22 : 0
                        visible: text.length > 0
                    }
                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: chapterName.visible ? chapterName.bottom : imageFrame.bottom
                        anchors.topMargin: chapterName.visible ? 1 : 7
                        text: SeasonUtils.chapterTimeLabel(modelData)
                        color: "#B8BDCC"
                        font.pixelSize: 15
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                    }
                }

                Keys.onPressed: {
                    root.userActivity()
                    if (event.key === Qt.Key_Left) {
                        if (index > 0) root._focusIndex(index - 1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Right) {
                        if (index + 1 < root.chapters.length) root._focusIndex(index + 1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select || event.key === Qt.Key_Ok) {
                        root.activateFocused(); event.accepted = true
                    } else if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape || event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                        root.closeToButton(); event.accepted = true
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { root._focusIndex(index); root.activateFocused() }
                }
            }
            }
        }
    }
}
