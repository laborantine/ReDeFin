import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SeasonUtils.js" as SeasonUtils

FocusScope {
    id: root
    width: parent ? parent.width : 1280
    implicitHeight: hasContent ? (28 + 8 + topPadFor(imageHeight) + imageHeight + 61) : 0
    height: implicitHeight
    visible: hasContent
    enabled: visible
    focus: false

    property string serverUrl: ""
    property string accessToken: ""
    property string itemId: ""
    property bool fetchEnabled: true
    property int sectionLeftMargin: 28
    property int cardWidth: 300
    property int imageHeight: 169
    // Même espacement horizontal que CastPage / SimilarItems.
    property int cardGap: 10

    // Profil adaptatif images chapitres :
    // normal plus propre sans coût excessif, HQ uniquement sur le chapitre
    // réellement focusé et stabilisé.
    readonly property real imageOversample: 1.30
    readonly property int imageQuality: 85
    readonly property int requestImageWidth: Math.max(1, Math.round(cardWidth * imageOversample))
    readonly property int requestImageHeight: Math.max(1, Math.round(imageHeight * imageOversample))
    readonly property real hqImageOversample: 1.50
    readonly property int hqImageQuality: 90
    readonly property int requestHqImageWidth: Math.max(1, Math.round(cardWidth * hqImageOversample))
    readonly property int requestHqImageHeight: Math.max(1, Math.round(imageHeight * hqImageOversample))
    property int hqTargetIndex: -1
    property int _hqPendingIndex: -1
    property int lastFocusedIndex: 0
    property var chapters: []
    property int _requestSeq: 0
    readonly property bool hasContent: !!(chapters && chapters.length > 0)

    // Même feeling que CastPage / GuestPage / SimilarItems.
    readonly property real focusScale: 1.14
    readonly property int focusLiftPx: 6
    readonly property real frameWidth: 2.0
    readonly property real frameInsetPx: 0.0
    readonly property real frameInnerEpsilon: 0.2
    readonly property int edgeNudgePx: Math.max(0, Math.ceil(cardWidth * (focusScale - 1) * 0.55))
    readonly property int edgePad: Math.max(18, edgeNudgePx + 10)
    readonly property int delegateWidth: cardWidth
    readonly property bool isScrolling: !!(chapterList && (chapterList.moving || chapterList.dragging || chapterList.flicking))
    readonly property bool allowAnims: !!(root.visible && !root.isScrolling)

    signal requestFocusAbove()
    signal requestFocusBelow()
    signal chapterActivated(int index, var chapter)

    function frameMargin(){ return frameInsetPx + frameWidth / 2 + frameInnerEpsilon }
    function topPadFor(h){ return Math.ceil(h * (focusScale - 1)) + focusLiftPx + Math.ceil(frameWidth) + 2 }
    function _cancelHq(){
        hqPromotionTimer.stop()
        _hqPendingIndex = -1
        hqTargetIndex = -1
    }
    function _scheduleHq(idx){
        hqPromotionTimer.stop()
        hqTargetIndex = -1
        idx = Number(idx) | 0
        if (!visible || isScrolling || !chapterList || !chapterList.activeFocus
                || idx < 0 || idx >= chapterList.count) {
            _hqPendingIndex = -1
            return
        }
        _hqPendingIndex = idx
        hqPromotionTimer.restart()
    }
    function _scheduleFetch(){
        _requestSeq++
        chapters = []
        focusRetry.stop()
        if (!fetchEnabled || !serverUrl || !accessToken || !itemId) { fetchTimer.stop(); return }
        fetchTimer.restart()
    }
    function _fetch(){
        if (!fetchEnabled || !serverUrl || !accessToken || !itemId) return
        var seq = _requestSeq, expectedServer = serverUrl, expectedToken = accessToken, expectedId = itemId
        Jellyfin.fetchItemChapters(expectedServer, expectedToken, expectedId,
            function(arr){
                if (seq !== _requestSeq || expectedServer !== serverUrl || expectedToken !== accessToken || expectedId !== itemId) return
                chapters = arr || []
                if (lastFocusedIndex >= chapters.length) lastFocusedIndex = Math.max(0, chapters.length - 1)
                chapterList.currentIndex = chapters.length ? lastFocusedIndex : -1
            },
            function(){
                if (seq !== _requestSeq || expectedServer !== serverUrl || expectedToken !== accessToken || expectedId !== itemId) return
                chapters = []
                chapterList.currentIndex = -1
            }
        )
    }

    function _itemAt(idx){
        if (!chapterList || idx < 0 || idx >= chapterList.count) return null
        try { return chapterList.itemAtIndex(idx) } catch(e) { return null }
    }
    Timer {
        id: focusRetry
        repeat: false
        interval: 0
        property int targetIndex: -1
        property int tries: 0
        onTriggered: {
            if (!root.visible || !root.hasContent || targetIndex < 0) return
            var obj = root._itemAt(targetIndex)
            if (obj && obj.forceActiveFocus) { obj.forceActiveFocus(); return }
            tries++
            if (tries < 10) { interval = 24; restart() }
        }
    }
    function _focusIndexSoon(idx){
        focusRetry.stop()
        focusRetry.targetIndex = idx
        focusRetry.tries = 0
        focusRetry.interval = 0
        focusRetry.restart()
    }
    function _focusIndex(idx){
        if (!hasContent) return false
        idx = Math.max(0, Math.min(chapters.length - 1, idx | 0))
        lastFocusedIndex = idx

        // Important : pas de positionViewAtIndex ici. Le déplacement horizontal
        // est confié au highlight-range, comme CastPage/GuestPage/SimilarItems.
        chapterList.currentIndex = idx
        chapterList.forceActiveFocus()
        _focusIndexSoon(idx)
        return true
    }
    function forceFirstFocus(){ return _focusIndex(0) }
    function restoreLastFocus(){ return _focusIndex(lastFocusedIndex) }

    onServerUrlChanged: _scheduleFetch()
    onAccessTokenChanged: _scheduleFetch()
    onItemIdChanged: _scheduleFetch()
    onFetchEnabledChanged: _scheduleFetch()
    onActiveFocusChanged: {
        if (activeFocus && hasContent && !(chapterList.currentItem && chapterList.currentItem.activeFocus))
            _focusIndexSoon(lastFocusedIndex)
        if (!activeFocus) _cancelHq()
    }
    onIsScrollingChanged: {
        if (isScrolling) _cancelHq()
        else if (chapterList && chapterList.activeFocus && chapterList.currentIndex >= 0)
            _scheduleHq(chapterList.currentIndex)
    }
    Component.onCompleted: _scheduleFetch()
    Component.onDestruction: { _requestSeq++; focusRetry.stop(); _cancelHq() }

    Timer { id: fetchTimer; interval: 150; repeat: false; onTriggered: root._fetch() }
    Timer {
        id: hqPromotionTimer
        interval: 300
        repeat: false
        onTriggered: {
            var idx = chapterList ? (chapterList.currentIndex | 0) : -1
            root.hqTargetIndex = (!root.isScrolling
                                  && chapterList && chapterList.activeFocus
                                  && idx >= 0
                                  && idx === root._hqPendingIndex)
                                 ? idx : -1
        }
    }

    Text {
        id: sectionTitle
        text: "Chapitres"
        color: "#FFFFFF"
        font.pixelSize: 20
        font.bold: true
        anchors.left: parent.left
        anchors.leftMargin: root.sectionLeftMargin
        anchors.top: parent.top
        height: 28
        verticalAlignment: Text.AlignVCenter
    }

    ListView {
        id: chapterList
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: sectionTitle.bottom
        anchors.topMargin: 8
        height: root.topPadFor(root.imageHeight) + root.imageHeight + 61
        orientation: ListView.Horizontal
        spacing: root.cardGap
        clip: true
        model: root.chapters
        currentIndex: -1

        // Glide identique CastPage / GuestPage / SimilarItems.
        snapMode: ListView.NoSnap
        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: root.edgePad
        preferredHighlightEnd: Math.max(0, width - root.delegateWidth - root.edgePad)
        highlightMoveDuration: root.visible ? 170 : 0
        highlightMoveVelocity: -1
        highlight: Item { width: root.delegateWidth; height: chapterList.height; visible: false }

        interactive: root.visible && (contentWidth > width + 2)
        boundsBehavior: Flickable.StopAtBounds
        flickDeceleration: 5000
        maximumFlickVelocity: 3200
        reuseItems: true
        cacheBuffer: Math.max(180, Math.min(620, Math.round(root.delegateWidth * 1.5)))

        header: Item { width: root.edgePad; height: 1 }
        footer: Item { width: root.edgePad; height: 1 }

        onEnabledChanged: {
            if (!enabled) {
                if (cancelFlick) cancelFlick()
                if (returnToBounds) returnToBounds()
            }
        }
        onVisibleChanged: {
            if (!visible) {
                if (cancelFlick) cancelFlick()
                if (returnToBounds) returnToBounds()
            }
        }

        delegate: FocusScope {
            id: chapterCard
            width: root.delegateWidth
            height: chapterList.height
            z: (chapterList.activeFocus && chapterList.currentIndex === index) ? 1000 : 0
            focus: ListView.isCurrentItem

            property bool imageFailed: false
            property int boundIndex: index
            // Le focus réel du delegate pilote l’animation, comme CastPage/SimilarItems.
            // Ne pas dépendre de chapterList.activeFocus : lors d’un Up/Down, cela permet
            // à scaleOut + Translate de jouer avant que la carte soit totalement au repos.
            readonly property bool selected: chapterCard.activeFocus
            onBoundIndexChanged: imageFailed = false
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
                id: posterCard
                x: 0
                y: root.topPadFor(root.imageHeight)
                width: root.cardWidth
                height: root.imageHeight
                transformOrigin: Item.Bottom
                scale: 1.0

                readonly property bool selected: chapterCard.selected
                readonly property bool isFirst: index === 0
                readonly property bool isLast: root.chapters && index === root.chapters.length - 1
                readonly property bool allowLocalAnims: root.allowAnims

                transform: Translate {
                    x: posterCard.selected
                       ? (posterCard.isFirst ? root.edgeNudgePx : (posterCard.isLast ? -root.edgeNudgePx : 0))
                       : 0
                    y: posterCard.selected ? -root.focusLiftPx : 0
                    Behavior on x { enabled: posterCard.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Behavior on y { enabled: posterCard.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                }

                function _applyScaleImmediate(){
                    if (scaleIn && scaleIn.stop) scaleIn.stop()
                    if (scaleOut && scaleOut.stop) scaleOut.stop()
                    posterCard.scale = posterCard.selected ? (root.focusScale - 0.02) : 1.0
                }

                SequentialAnimation {
                    id: scaleIn
                    running: false
                    PropertyAnimation { target: posterCard; property: "scale"; to: root.focusScale; duration: 120; easing.type: Easing.OutCubic }
                    PropertyAnimation { target: posterCard; property: "scale"; to: (root.focusScale - 0.02); duration: 90; easing.type: Easing.OutCubic }
                }
                NumberAnimation {
                    id: scaleOut
                    target: posterCard
                    property: "scale"
                    to: 1.0
                    duration: 130
                    easing.type: Easing.OutCubic
                    running: false
                }

                onSelectedChanged: {
                    if (!allowLocalAnims) { _applyScaleImmediate(); return }
                    if (selected) { scaleOut.stop(); scaleIn.start() }
                    else { scaleIn.stop(); scaleOut.start() }
                }
                onVisibleChanged: if (visible) _applyScaleImmediate()
                Connections { target: root; function onIsScrollingChanged(){ if (root.isScrolling) posterCard._applyScaleImmediate() } }

                Rectangle {
                    anchors.fill: parent
                    color: "#11141c"
                    visible: true
                }

                Item {
                    id: imageClip
                    anchors.fill: parent
                    clip: true

                    Item {
                        id: clapFallback
                        anchors.fill: parent
                        visible: !chapterImage.source || chapterImage.status !== Image.Ready || chapterCard.imageFailed
                        Rectangle { anchors.fill: parent; color: "#10131A" }
                        Rectangle {
                            id: clapperTop
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
                                    width: Math.round(clapperTop.width / 8)
                                    height: clapperTop.height * 1.8
                                    x: index * Math.round(clapperTop.width / 5) - 8
                                    y: -Math.round(clapperTop.height * 0.4)
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
                        smooth: !root.isScrolling
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
                                 && !root.isScrolling
                                 && chapterImage.status === Image.Ready
                                 && root.hqTargetIndex === index)
                                ? SeasonUtils.chapterImageUrl(root.serverUrl, root.itemId, root.chapters, index, root.requestHqImageWidth, root.requestHqImageHeight, root.hqImageQuality) : ""
                        asynchronous: true
                        cache: false
                        mipmap: false
                        smooth: !root.isScrolling
                        fillMode: Image.PreserveAspectCrop
                        visible: source !== "" && status === Image.Ready && !chapterCard.imageFailed
                        opacity: visible ? 1.0 : 0.0
                        Behavior on opacity {
                            enabled: root.allowAnims
                            NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
                        }
                    }
                }

                // Cadre focus exactement superposé à la vignette.
                // Aucune marge : le bord blanc épouse pixel pour pixel imageClip
                // et reste dans le même Item transformé que le poster, donc il suit
                // exactement le zoom, le lift et l'edge-nudge.
                Rectangle {
                    anchors.fill: imageClip
                    anchors.margins: 0
                    color: "transparent"
                    border.color: "#FFFFFF"
                    border.width: root.frameWidth
                    opacity: posterCard.selected ? 1.0 : 0.0
                    antialiasing: false
                    Behavior on opacity {
                        enabled: posterCard.allowLocalAnims
                        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                    }
                    z: 3
                }
            }

            Text {
                id: chapterName
                x: 0
                y: root.topPadFor(root.imageHeight) + root.imageHeight + 8
                width: root.cardWidth
                text: SeasonUtils.chapterTitle(modelData)
                color: "#FFFFFF"
                font.pixelSize: 18
                font.bold: chapterCard.selected
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                height: text.length > 0 ? 23 : 0
                visible: text.length > 0
            }
            Text {
                x: 0
                y: chapterName.visible ? (chapterName.y + chapterName.height + 2)
                                       : (root.topPadFor(root.imageHeight) + root.imageHeight + 8)
                width: root.cardWidth
                text: SeasonUtils.chapterTimeLabel(modelData)
                color: "#B8BDCC"
                font.pixelSize: 16
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
            }

            Keys.onPressed: {
                if (event.key === Qt.Key_Left) {
                    if (index > 0) root._focusIndex(index - 1)
                    event.accepted = true
                } else if (event.key === Qt.Key_Right) {
                    if (index + 1 < root.chapters.length) root._focusIndex(index + 1)
                    event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                    root.requestFocusAbove(); event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                    root.requestFocusBelow(); event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select || event.key === Qt.Key_Ok) {
                    root.chapterActivated(index, modelData); event.accepted = true
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: root._focusIndex(index)
            }
        }
    }
}
